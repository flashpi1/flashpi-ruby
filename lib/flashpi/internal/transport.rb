# frozen_string_literal: true

module Flashpi
  module Internal
    # The time an attempt has left, from sending it to reading the whole answer.
    #
    # @api private
    class Deadline
      def initialize(seconds, clock = Clock)
        @clock = clock
        @end = clock.now + seconds
      end

      # @return [Float] seconds left (0 or less once it has passed)
      def left
        @end - @clock.now
      end

      # @return [Boolean]
      def passed?
        left <= 0
      end

      # The seconds left; `error` once there are none.
      #
      # @return [Float]
      def left!(error)
        seconds = left
        raise error, "The attempt's deadline passed" if seconds <= 0

        seconds
      end

      # `timeout` cut to the seconds left; `error` once there are none.
      #
      # @return [Float]
      def limit(timeout, error)
        seconds = left!(error)
        timeout.nil? ? seconds : [timeout, seconds].min
      end

      def inspect
        "#<#{self.class.name} left=#{left.round(3)}>"
      end
    end

    # The deadline of an attempt, down to each network operation of net/http.
    #
    # net/http gives connecting, the TLS handshake, each write and each wait for data a timeout of
    # its own, so an answer that trickles in could keep an attempt going for as long as it
    # trickles. Extended onto each Net::HTTP the SDK creates, this module limits connecting and
    # the TLS handshake to the time the attempt has left, and wraps the connection's socket in a
    # {DeadlineSocket} that does the same for every read and write. It hooks into net/http
    # through `connect`, `ssl_socket_connect` and `on_connect`, and replaces the `@socket` that
    # `connect` builds (pinned by test/transport_test.rb): if net/http changes them, the socket is
    # left as it is and the timeouts set at the start of each attempt still apply.
    #
    # @api private
    module DeadlineHTTP
      # @return [Deadline, nil] the deadline of the attempt running on this connection
      attr_accessor :flashpi_deadline

      private

      def connect
        deadline = flashpi_deadline
        return super unless deadline # steep:ignore

        @open_timeout = deadline.left!(Net::OpenTimeout)
        return super unless proxy? && use_ssl? # steep:ignore

        # Through a proxy, net/http sends the CONNECT of an https connection and reads its answer
        # on a socket this module does not wrap, each read with a timeout of its own: the whole
        # connect is limited to the time the attempt has left instead (net/http itself limits
        # connecting this way before 0.6).
        Timeout.timeout(deadline.left!(Net::OpenTimeout), Net::OpenTimeout) { super } # steep:ignore
      end

      def ssl_socket_connect(socket, timeout)
        deadline = flashpi_deadline
        super(socket, deadline ? deadline.limit(timeout, Net::OpenTimeout) : timeout) # steep:ignore
      end

      def on_connect
        super # steep:ignore
        socket = @socket
        return unless socket.is_a?(Net::BufferedIO) && !socket.io.is_a?(DeadlineSocket) # steep:ignore

        @socket = Net::BufferedIO.new( # steep:ignore
          DeadlineSocket.new(socket.io, self),
          read_timeout: socket.read_timeout,
          write_timeout: socket.write_timeout,
          continue_timeout: socket.continue_timeout,
          debug_output: socket.debug_output
        )
      end
    end

    # A connection's socket whose reads, writes and waits keep the deadline of the attempt
    # running on it. Net::BufferedIO waits on `to_io`, which is this object.
    #
    # @api private
    class DeadlineSocket
      # @return [IO, OpenSSL::SSL::SSLSocket] the socket
      attr_reader :io

      def initialize(io, http)
        @io = io
        @http = http
      end

      def read_nonblock(length, buffer = nil, exception: true)
        deadline&.left!(Net::ReadTimeout)
        @io.read_nonblock(length, buffer, exception:)
      end

      def write_nonblock(data, exception: true)
        deadline&.left!(Net::WriteTimeout)
        @io.write_nonblock(data, exception:)
      end

      def to_io
        self
      end

      # Waits until the socket is readable, at most `timeout` seconds and the time the attempt has
      # left. A zero timeout (net/http checking an idle connection) answers nil when it is not;
      # otherwise the timeout raises here, from a frame that holds no request data (error
      # trackers can record the local variables of the method that raises).
      #
      # @return [Object] truthy
      def wait_readable(timeout = nil)
        return @io.to_io.wait_readable(timeout) if timeout&.zero?

        @io.to_io.wait_readable(limited(timeout, Net::ReadTimeout)) || raise(Net::ReadTimeout)
      end

      # Waits until the socket is writable, as {#wait_readable}.
      #
      # @return [Object] truthy
      def wait_writable(timeout = nil)
        return @io.to_io.wait_writable(timeout) if timeout&.zero?

        @io.to_io.wait_writable(limited(timeout, Net::WriteTimeout)) || raise(Net::WriteTimeout)
      end

      def close
        @io.close
      end

      def closed?
        @io.closed?
      end

      # Always true. net/http calls it only to check an idle connection that has something to
      # read before reusing it: such a connection is closed instead (on TLS, the socket's own
      # eof? could block, without a timeout, on a record that never ends).
      def eof?
        true
      end

      def inspect
        @io.inspect
      end

      def respond_to_missing?(name, include_private = false)
        @io.respond_to?(name, include_private) || super
      end

      def method_missing(name, ...)
        @io.respond_to?(name) ? @io.public_send(name, ...) : super
      end

      private

      def deadline
        @http.flashpi_deadline
      end

      def limited(timeout, error)
        current = deadline
        current ? current.limit(timeout, error) : timeout
      end
    end

    # The proxy of a client's connections, from the environment variables of its base URL's scheme,
    # as curl and httpx read them: `https_proxy` (or `HTTPS_PROXY`) for https, `http_proxy` for
    # http (`HTTP_PROXY` too, except in a CGI request, where a client can set it), and
    # `no_proxy` (or `NO_PROXY`, `*` for every host). A loopback host never goes through a
    # proxy. Read once, when the client is created, and only http:// proxies (net/http before
    # 0.6 cannot reach a proxy over TLS). net/http's own lookup would read `http_proxy` for
    # https too and look the host up in DNS on every connection.
    #
    # @api private
    module Proxy
      LOOPBACK = /\A(?:localhost|127(?:\.[0-9]{1,3}){3}|::1)\z/i

      module_function

      # @return [Array(String, Integer, String, String), nil] host, port, user and password
      # @raise [Flashpi::Error] for a proxy that is not an http:// URL, without showing it
      def from_env(uri, env = ENV)
        name = "#{uri.scheme}_proxy"
        value = env[name]
        value = env[name.upcase] if value.nil? && !(name == "http_proxy" && env.key?("REQUEST_METHOD"))
        return nil if value.nil? || value.strip.empty?

        host = uri.hostname.to_s
        return nil if LOOPBACK.match?(host) || bypassed?(uri, env["no_proxy"] || env["NO_PROXY"])

        parse(name, value.strip)
      end

      # @api private
      def bypassed?(uri, no_proxy)
        return false if no_proxy.nil? || no_proxy.strip.empty?
        return true if no_proxy.strip == "*"

        host = uri.hostname.to_s
        # The host as its own address: a CIDR of no_proxy matches an IP host, and is skipped for a
        # name, without a DNS lookup.
        !URI::Generic.use_proxy?(host, host, uri.port || 0, no_proxy)
      end

      # @api private
      def parse(name, value)
        proxy = URI.parse(value.include?("://") ? value : "http://#{value}")
        refuse!(name) unless proxy.scheme == "http" && !proxy.hostname.to_s.empty?

        user = (encoded = proxy.user) && URI.decode_uri_component(encoded)
        password = (encoded = proxy.password) && URI.decode_uri_component(encoded)
        [proxy.hostname.to_s, proxy.port || 80, user, password]
      rescue URI::Error
        refuse!(name)
      end

      # Raises from a frame that holds only the variable's name: its value may carry a password.
      #
      # @api private
      def refuse!(name)
        raise Error, "The #{name} environment variable is not an http:// proxy URL", cause: nil
      end
    end

    # Sends attempts with net/http and reads their whole answer within the attempt's deadline.
    #
    # Connections are kept alive and reused, one attempt at a time each, from a pool that is safe
    # to share between threads. After a fork the child drops the parent's connections without
    # closing them (closing would end the parent's TLS sessions). The proxy comes from the
    # environment ({Proxy}). Redirects are never followed: net/http does not follow them.
    #
    # @api private
    class Transport
      MAX_IDLE = 10

      # Not Timeout::Error itself: a caller's Timeout.timeout around a call must stop it, not be
      # retried. net/http's own timeouts are the TIMEOUT_ERRORS.
      CONNECTION_ERRORS = [
        SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError, Net::ProtocolError, Zlib::Error
      ].freeze
      TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IO::TimeoutError].freeze

      REQUESTS = {
        get: Net::HTTP::Get,
        post: Net::HTTP::Post,
        patch: Net::HTTP::Patch,
        delete: Net::HTTP::Delete
      }.freeze

      # @param base_url [String] an http(s) URL with a host
      def initialize(base_url, clock = Clock)
        uri = URI.parse(base_url)
        @host = uri.hostname.to_s
        @port = uri.port || (uri.scheme == "https" ? 443 : 80)
        @use_ssl = uri.scheme == "https"
        @proxy = Proxy.from_env(uri)
        @clock = clock
        @idle = []
        @mutex = Mutex.new
        @pid = Process.pid
      end

      # Sends one attempt and reads its whole answer before its deadline.
      #
      # @param attempt [Attempt]
      # @return [RawResponse]
      # @raise [Flashpi::APITimeoutError] when the deadline passed
      # @raise [Flashpi::APIConnectionError] when there was no answer
      # @raise [Flashpi::Error] when net/http refused to send the request
      def perform(attempt)
        deadline = Deadline.new(attempt.timeout, @clock)
        http = checkout
        reusable = false
        begin
          response = exchange(http, attempt, deadline)
          reusable = true
          response
        rescue *TIMEOUT_ERRORS
          raise APITimeoutError, "#{attempt.verb} #{attempt.url} timed out after #{seconds(attempt.timeout)} seconds"
        rescue *CONNECTION_ERRORS => e
          reason = e.message.empty? ? e.class.name : e.message
          raise APIConnectionError, "#{attempt.verb} #{attempt.url} failed: #{reason}"
        ensure
          reusable ? checkin(http) : discard(http)
        end
      end

      # Closes the idle connections. The transport can still be used: it opens new ones.
      def close
        idle = @mutex.synchronize do
          connections = forked? ? [] : @idle #: Array[Net::HTTP & DeadlineHTTP]
          @idle = []
          connections
        end
        idle.each { |http| discard(http) }
        nil
      end

      def inspect
        "#<#{self.class.name} #{@use_ssl ? "https" : "http"}://#{@host}:#{@port}>"
      end

      private

      def exchange(http, attempt, deadline)
        inflate = nil #: Zlib::Inflate?
        http.flashpi_deadline = deadline
        limit_timeouts(http, deadline)
        http.start unless http.started?
        status = 0
        headers = {} #: Hash[String, String]
        body = String.new(encoding: Encoding::BINARY)
        http.request(build_request(attempt), attempt.content) do |response|
          status = response.code.to_i
          response.each_header { |name, value| headers[name] = value.dup.force_encoding(Encoding::UTF_8).scrub }
          inflate = gzip_inflater(response)
          response.read_body do |chunk|
            deadline.left!(Net::ReadTimeout)
            body << (inflate ? inflate.inflate(chunk) : chunk)
          end
        end
        # A gzip stream that ends early raises Zlib::BufError here: no answer, retried.
        body << inflate.finish if inflate&.total_in&.positive?
        # Also an answer whose end came late.
        deadline.left!(Net::ReadTimeout)
        RawResponse.new(status, headers, body)
      ensure
        inflate&.close # steep:ignore FallbackAny
        http.flashpi_deadline = nil
      end

      # The SDK decompresses gzip answers itself: net/http would return what it had inflated so
      # far of a gzip stream that ends early, as a complete answer.
      def gzip_inflater(response)
        encoding = response["content-encoding"].to_s.strip.downcase
        Zlib::Inflate.new(32 + Zlib::MAX_WBITS) if %w[gzip x-gzip].include?(encoding)
      end

      def limit_timeouts(http, deadline)
        seconds = deadline.left!(Net::OpenTimeout)
        http.open_timeout = seconds
        http.read_timeout = seconds
        http.write_timeout = seconds
      end

      # A request net/http refuses to build raises Flashpi::Error, not retried, and without its
      # reason, which may quote the refused header (possibly the Authorization one).
      def build_request(attempt)
        request_class = REQUESTS.fetch(attempt.http_method) #: singleton(Net::HTTPRequest)
        # Asking for gzip turns net/http's own decompression off (see #gzip_inflater).
        request = request_class.new(attempt.target, { "accept-encoding" => "gzip" }.merge(attempt.headers))
        # net/http before 0.7 (Ruby 3.3 and 3.4) gives a POST without a body the Content-Type
        # application/x-www-form-urlencoded; it is sent with Content-Length: 0 and no Content-Type,
        # as the other SDKs send it.
        request.define_singleton_method(:supply_default_content_type) { nil } if attempt.content.nil?
        request
      rescue ArgumentError
        raise Error, "#{attempt.verb} #{attempt.url} was not sent: net/http refused it as invalid HTTP", cause: nil
      end

      def checkout
        connection = @mutex.synchronize do
          if forked?
            @idle = []
            @pid = Process.pid
          end
          @idle.pop
        end
        connection || connect
      end

      def checkin(http)
        kept = @mutex.synchronize do
          if !forked? && @idle.size < MAX_IDLE
            @idle.push(http)
            true
          else
            false
          end
        end
        discard(http) unless kept
      end

      def discard(http)
        http.finish if http.started?
      rescue StandardError
        nil
      end

      def connect
        proxy_host, proxy_port, proxy_user, proxy_password = @proxy
        http = Net::HTTP.new(@host, @port, proxy_host, proxy_port, proxy_user, proxy_password)
        http.use_ssl = @use_ssl
        # The SDK retries by its own rules (idempotency keys, recoveries), never net/http.
        http.max_retries = 0
        # An answer cut before its Content-Length is a failure (retried), not a shorter answer.
        http.ignore_eof = false # steep:ignore
        http.extend(DeadlineHTTP)
        _ = http
      end

      def forked?
        @pid != Process.pid
      end

      def seconds(value)
        format("%.3f", value).sub(/\.?0+\z/, "")
      end
    end
  end
end
