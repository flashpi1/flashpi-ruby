# frozen_string_literal: true

module Flashpi
  module Internal
    # Requests to the Flashpi API: retries, timeouts, idempotency and typed errors.
    #
    # @api private
    class Engine
      USER_AGENT = "flashpi-ruby/#{VERSION}".freeze

      # Longest `Retry-After`, in seconds, the SDK waits for by itself; longer waits (daily quotas)
      # are raised.
      MAX_RETRY_AFTER = 60

      INITIAL_RETRY_DELAY = 0.5
      MAX_RETRY_DELAY = 8.0
      # Waits between checks on an earlier attempt that the API is still running.
      IN_PROGRESS_FIRST_WAIT = 1.0
      IN_PROGRESS_MAX_WAIT = 5.0
      IN_PROGRESS = "idempotency_key_in_progress"

      OPTION_NAMES = %i[idempotency_key timeout max_retries language correlation_id extra_headers].freeze

      # What every attempt of one call shares, resolved before the first one is sent. It is a local
      # of the methods that raise the call's errors, and error trackers can record those locals: the
      # body (possibly a .p12 and its password) is kept in a Secret, and `inspect` shows the URL only.
      class Call
        attr_reader :options, :max_retries, :timeout, :url, :target, :idempotency_key

        def initialize(options:, max_retries:, timeout:, url:, target:, idempotency_key:, content:)
          @options = options
          @max_retries = max_retries
          @timeout = timeout
          @url = url
          @target = target
          @idempotency_key = idempotency_key
          @content = Secret.new(content)
          freeze
        end

        # @return [String, nil] the body every attempt sends
        def content
          @content.reveal
        end

        def inspect
          "#<#{self.class.name} #{url}>"
        end
      end
      private_constant :Call

      # @return [ClientConfig]
      attr_reader :config
      # @return [Transport] how attempts are sent (tests replace it)
      attr_accessor :transport
      # @return [#now, #sleep, #rand] the clock of retries and waits (tests replace it)
      attr_accessor :clock

      def initialize(config, transport, clock = Clock)
        @config = config
        @transport = transport
        @clock = clock
        @base_path = URI.parse(config.base_url).path.to_s.sub(%r{/+\z}, "")
      end

      # Sends a request with its retries and recoveries.
      #
      # @param spec [RequestSpec]
      # @return [Flashpi::APIResponse]
      def request(spec)
        call = prepare(spec)
        started = clock.now
        attempt = retries = waits = 0
        # Whether an earlier attempt may have reached the API without its answer reaching us (a
        # network error, a timeout, or a 5xx from a proxy). Only then can a 409
        # idempotency_key_in_progress be this call's own attempt still running.
        unanswered = false

        loop do
          failure = attempt_once(spec, call)
          return failure if failure.is_a?(APIResponse)

          # The error of this attempt: an APIError or an APIConnectionError.
          failure.idempotency_key = call.idempotency_key

          if attempt.positive? && failure.is_a?(APIError)
            document_id = recoverable_document(spec, failure)
            return recover_document(call, document_id) if document_id
            # A DELETE retried after a lost answer finds the resource already gone.
            return deleted(failure) if spec.http_method == :delete && failure.status == 404

            # This call's earlier attempt is still running on the API (a sync issue whose answer
            # was lost): wait for it with the same key while the call has time left. These checks
            # do not count as retries; once the time is up, the normal retry rules apply.
            if unanswered && failure.status == 409 && failure.code == IN_PROGRESS
              wait = [IN_PROGRESS_FIRST_WAIT * (2**[waits, 16].min), IN_PROGRESS_MAX_WAIT].min
              if clock.now + wait - started <= call.timeout
                waits += 1
                attempt += 1
                clock.sleep(wait)
                next
              end
            end
          end

          unanswered = true if unanswered?(failure)
          delay = retry_delay(failure, retries)
          raise failure if delay.nil? || retries >= call.max_retries

          retries += 1
          attempt += 1
          clock.sleep(delay)
        end
      end

      private

      # One attempt: its APIResponse, or the APIError or APIConnectionError to handle. Any other
      # Flashpi::Error is raised with the call's Idempotency-Key.
      def attempt_once(spec, call)
        raw = transport.perform(attempt_of(spec, call))
        read_response(raw, spec.response_type)
      rescue APIConnectionError => e
        e
      rescue Error => e
        e.idempotency_key = call.idempotency_key
        raise
      end

      # Whether the attempt may have reached the API without its answer reaching us: a network
      # error, a timeout, or a 5xx from a proxy (no Problem Details).
      def unanswered?(failure)
        failure.is_a?(APIConnectionError) || (failure.is_a?(APIError) && failure.status >= 500 && failure.problem.nil?)
      end

      # Checks the options and builds what the attempts share. Raises before anything is sent.
      def prepare(spec)
        options = check_options(spec.options)
        max_retries = if options[:max_retries].nil?
                        config.max_retries
                      else
                        Validate.retries!("max_retries",
                                          options[:max_retries])
                      end
        timeout = options[:timeout].nil? ? config.timeout : Validate.timeout!("timeout", options[:timeout])
        target = build_target(spec.path, spec.query)
        longest = [spec.min_timeout, timeout].max
        Call.new(
          options:,
          max_retries:,
          timeout: [longest, Validate::MAX_TIMEOUT].min,
          url: config.base_url.sub(%r{/+\z}, "") + target,
          target: @base_path + target,
          idempotency_key: idempotency_key_of(spec.http_method, options),
          # Serialized once: every attempt sends the same bytes under the same Idempotency-Key,
          # even when the caller changes the body meanwhile.
          content: spec.multipart ? spec.multipart.content : body_content(spec)
        )
      end

      def body_content(spec)
        spec.body.nil? ? nil : JSONText.encode(spec.body)
      end

      def attempt_of(spec, call)
        Attempt.new(
          http_method: spec.http_method,
          url: call.url,
          target: call.target,
          headers: build_headers(spec, call),
          content: call.content,
          timeout: call.timeout,
          response_type: spec.response_type
        )
      end

      # Reads the document an earlier attempt of the call created. A failure to read it keeps the
      # call's key on the error, so trying again later with that key returns the document instead
      # of issuing another.
      def recover_document(call, document_id)
        options = call.options.except(:idempotency_key)
        request(RequestSpec.new(http_method: :get, path: Path.of("/v1/documents/{}", document_id), options:))
      rescue Error => e
        e.idempotency_key = call.idempotency_key
        raise
      end

      # Seconds to wait before retrying, or nil when the failure must not be retried.
      #
      # Retried: network errors and timeouts, 408, 429 and 5xx except 501 (with a `Retry-After` of
      # {MAX_RETRY_AFTER} or less), and 409 `idempotency_key_in_progress` (an attempt with the
      # same key is still running). POSTs are safe to retry because they keep their
      # Idempotency-Key.
      def retry_delay(failure, retries)
        return backoff(retries) if failure.is_a?(APIConnectionError)
        return nil unless failure.is_a?(APIError)

        status = failure.status
        return failure.code == IN_PROGRESS ? [IN_PROGRESS_FIRST_WAIT, backoff(retries)].max : nil if status == 409

        transient = [408, 429].include?(status) || (status >= 500 && status != 501)
        # The shared demo certificate is missing: no retry within seconds will fix that.
        return nil if !transient || failure.code == "demo_issuer_unavailable"

        retry_after = failure.retry_after
        return backoff(retries) if retry_after.nil?

        retry_after <= MAX_RETRY_AFTER ? retry_after.to_f : nil
      end

      # Exponential backoff from 0.5 s up to 8 s, minus up to 25 % of jitter.
      def backoff(retries)
        delay = [INITIAL_RETRY_DELAY * (2**[retries, 16].min), MAX_RETRY_DELAY].min
        (delay * (1 - (clock.rand * 0.25))).round(3).to_f
      end

      # The id of the document an earlier attempt of this call created, if the answer shows one.
      def recoverable_document(spec, failure)
        return nil unless spec.recover_document && failure.status == 422 && failure.code == "idempotency_key_reused"

        document_id = (failure.problem || {})[:documentId]
        document_id.is_a?(String) && !document_id.empty? ? document_id : nil
      end

      # The result of a DELETE whose resource is gone: a 204 with the 404's headers.
      def deleted(failure)
        dropped = %w[content-length content-type content-encoding transfer-encoding]
        headers = failure.headers.except(*dropped)
        APIResponse.new(data: nil, status: 204, headers:, request_id: failure.request_id)
      end

      # The caller's options with the values that become headers checked and trimmed, so the
      # attempts, the errors and a recovered read all use the same ones.
      def check_options(options)
        unknown = options.keys - OPTION_NAMES
        unless unknown.empty?
          raise ArgumentError, "Unknown request options: #{unknown.map(&:inspect).join(", ")}. The options are " \
                               "#{OPTION_NAMES.join(", ")}; bodies and list filters go in a Hash before them"
        end

        checked = options.dup
        unless options[:extra_headers].nil?
          checked[:extra_headers] =
            Validate.headers!("extra_headers", options[:extra_headers])
        end
        %i[idempotency_key correlation_id].each do |name|
          checked[name] = Validate.header_value!(name.to_s, options[name]) unless options[name].nil?
        end
        checked[:language] = language("language", options[:language]) unless options[:language].nil?
        checked
      end

      def language(label, value)
        Validate.header_value!(label, value.is_a?(Symbol) ? value.to_s : value)
      end

      # The caller's Idempotency-Key of a POST (option or header), or a new one.
      def idempotency_key_of(http_method, options)
        return nil unless http_method == :post
        return options[:idempotency_key] unless options[:idempotency_key].nil?

        # The last spelling wins, as in build_headers.
        header = nil
        (options[:extra_headers] || {}).each { |name, value| header = value if name.downcase == "idempotency-key" }
        header || SecureRandom.uuid
      end

      # The path and query of a request, after the base URL. Query values that are nil are left
      # out.
      def build_target(path, query)
        pairs = (query || {}).filter_map do |name, value|
          [query_name(name), query_value(value)] unless value.nil?
        end #: Array[[String, String]]
        search = URI.encode_www_form(pairs)
        search.empty? ? path : "#{path}?#{search}"
      end

      def query_name(name)
        return name.to_s if name.is_a?(Symbol) || name.is_a?(String)

        raise TypeError, "Filter names must be Strings or Symbols, not #{name.class}"
      end

      def query_value(value)
        case value
        when true then "true"
        when false then "false"
        when String, Symbol then query_text(value.to_s)
        when Integer then value.to_s
        when Float
          raise ArgumentError, "A filter cannot be NaN or infinite" unless value.finite?

          value.to_s
        when Date then value.iso8601
        else raise TypeError, "Filter values must be Strings, numbers, booleans or Dates, not #{value.class}"
        end
      end

      # A filter as UTF-8 text, as the API reads the query.
      def query_text(value)
        text = Validate.utf8(value)
        raise ArgumentError, "A filter must be valid UTF-8 text" if text.nil?

        text
      end

      # The headers of an attempt, by lowercase name, from the lowest priority to the highest:
      # client language, client headers, request language, request headers, then the SDK's own.
      def build_headers(spec, call)
        headers = { "accept" => spec.accept, "user-agent" => USER_AGENT }
        language = config.language
        headers["accept-language"] = language if language && !language.empty?
        config.default_headers.each { |name, value| headers[name.downcase] = value }
        language = call.options[:language]
        headers["accept-language"] = language if language && !language.empty?
        (call.options[:extra_headers] || {}).each { |name, value| headers[name.downcase] = value }
        headers["x-correlation-id"] = call.options[:correlation_id] unless call.options[:correlation_id].nil?
        headers["idempotency-key"] = call.idempotency_key unless call.idempotency_key.nil?
        if spec.multipart
          headers["content-type"] = spec.multipart.content_type
        elsif !spec.body.nil?
          headers["content-type"] = "application/json"
        end
        headers["authorization"] = "Bearer #{config.api_key}"
        headers
      end

      # The data of a successful answer, or the APIError of an error status.
      def read_response(raw, response_type)
        return Problems.error(raw.status, raw.headers, JSONText.decode(raw.body)) unless (200..299).cover?(raw.status)

        APIResponse.new(
          data: read_data(raw, response_type),
          status: raw.status,
          headers: raw.headers,
          request_id: raw.headers["x-request-id"]
        )
      end

      def read_data(raw, response_type)
        return raw.body if response_type == :bytes

        text = JSONText.decode(raw.body)
        return text if response_type == :text
        return nil if response_type == :none || raw.status == 204 || text.empty?

        begin
          JSONText.parse(text)
        rescue JSONText::Invalid
          raise Error, "The API answered #{raw.status} with a body that is not JSON"
        end
      end
    end
  end
end
