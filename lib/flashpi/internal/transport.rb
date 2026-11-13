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
        @open_timeout = deadline.left!(Net::OpenTimeout) if deadline
        super # steep:ignore
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

      def eof?
        @io.eof?
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

    # Sends attempts with net/http and reads their whole answer within the attempt's deadline.
    #
    # Connections are kept alive and reused, one attempt at a time each, from a pool that is safe
    # to share between threads. After a fork the child drops the parent's connections without
    # closing them (closing would end the parent's TLS sessions). Proxies come from the
    # environment (`https_proxy`, `no_proxy`), as net/http reads them. Redirects are never
    # followed: net/http does not follow them.
    #
    # @api private
    class Transport
      MAX_IDLE = 10

      CONNECTION_ERRORS = [
        SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse,
        Net::HTTPHeaderSyntaxError, Net::ProtocolError, Zlib::Error, Timeout::Error
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
        http.flashpi_deadline = deadline
        limit_timeouts(http, deadline)
        http.start unless http.started?
        status = 0
        headers = {} #: Hash[String, String]
        body = String.new(encoding: Encoding::BINARY)
        http.request(build_request(attempt), attempt.content) do |response|
          status = response.code.to_i
          response.each_header { |name, value| headers[name] = value }
          response.read_body do |chunk|
            deadline.left!(Net::ReadTimeout)
            body << chunk
          end
        end
        # Also an answer whose end came late.
        deadline.left!(Net::ReadTimeout)
        RawResponse.new(status, headers, body)
      ensure
        http.flashpi_deadline = nil
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
        request = request_class.new(attempt.target, attempt.headers)
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
        http = Net::HTTP.new(@host, @port)
        http.use_ssl = @use_ssl
        # The SDK retries by its own rules (idempotency keys, recoveries), never net/http.
        http.max_retries = 0
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
