# frozen_string_literal: true

module Flashpi
  module Internal
    # The settings of a client that the requests need. The API key is kept in a {Secret}.
    #
    # @api private
    class ClientConfig
      attr_reader :base_url, :timeout, :max_retries, :language, :default_headers

      def initialize(api_key:, base_url:, timeout:, max_retries:, language:, default_headers:)
        @api_key = Secret.new(api_key)
        @base_url = base_url
        @timeout = timeout
        @max_retries = max_retries
        @language = language
        @default_headers = default_headers.freeze
        freeze
      end

      # @return [String]
      def api_key
        @api_key.reveal
      end

      # Never the API key.
      def inspect
        "#<#{self.class.name} base_url=#{base_url.inspect} timeout=#{timeout} max_retries=#{max_retries}>"
      end
    end

    # One API operation, as the resources declare it.
    #
    # @api private
    class RequestSpec
      # @return [Symbol] :get, :post, :patch or :delete
      attr_reader :http_method
      # @return [String] the path, built with {Path.of} when it carries ids
      attr_reader :path
      # @return [Hash, nil] query parameters; nil values are left out
      attr_reader :query
      # @return [Object] a JSON body, serialized once for every attempt; nil sends no body
      attr_reader :body
      # @return [Multipart, nil] a multipart body, instead of `body`
      attr_reader :multipart
      # @return [String] the Accept header
      attr_reader :accept
      # @return [Symbol] how to read a successful answer: :json, :text, :bytes or :none
      attr_reader :response_type
      # @return [Hash{Symbol => Object}] the caller's options
      attr_reader :options
      # @return [Float] a floor, in seconds, for the timeout of requests the API holds open
      attr_reader :min_timeout
      # @return [Boolean] for document POSTs: return the document an earlier attempt created
      attr_reader :recover_document

      def initialize(http_method:, path:, query: nil, body: nil, multipart: nil, accept: "application/json",
                     response_type: :json, options: {}, min_timeout: 0.0, recover_document: false)
        @http_method = http_method
        @path = path
        @query = query
        @body = body
        @multipart = multipart
        @accept = accept
        @response_type = response_type
        @options = options
        @min_timeout = min_timeout
        @recover_document = recover_document
        freeze
      end

      # The same request with other query parameters (the next page of a list).
      #
      # @return [RequestSpec]
      def with_query(query)
        RequestSpec.new(http_method:, path:, query:, body:, multipart:, accept:, response_type:, options:,
                        min_timeout:, recover_document:)
      end

      def inspect
        "#<#{self.class.name} #{http_method.to_s.upcase} #{path}>"
      end
    end

    # One attempt of a call: what the transport sends.
    #
    # @api private
    class Attempt
      attr_reader :http_method, :url, :target, :timeout, :response_type

      # @param http_method [Symbol]
      # @param url [String] the whole URL, for messages
      # @param target [String] the path and query sent in the request line
      # @param headers [Hash{String => String}] by lowercase name; they carry the API key
      # @param content [String, nil] the body
      # @param timeout [Float] seconds the attempt may take
      # @param response_type [Symbol]
      def initialize(http_method:, url:, target:, headers:, content:, timeout:, response_type:)
        @http_method = http_method
        @url = url
        @target = target
        @headers = Secret.new(headers.freeze)
        @content = Secret.new(content)
        @timeout = timeout
        @response_type = response_type
        freeze
      end

      # @return [String, nil] the body, which may be a .p12 and its password
      def content
        @content.reveal
      end

      # @return [Hash{String => String}] the headers, with the API key
      def headers
        @headers.reveal
      end

      # @return [String] the method in capitals
      def verb
        http_method.to_s.upcase
      end

      def inspect
        "#<#{self.class.name} #{verb} #{url}>"
      end
    end

    # The answer of an attempt, as the transport read it.
    #
    # @api private
    class RawResponse
      attr_reader :status, :headers, :body

      # @param status [Integer]
      # @param headers [Hash{String => String}] by lowercase name
      # @param body [String] the bytes of the body
      def initialize(status, headers, body)
        @status = status
        @headers = headers.freeze
        @body = body
        freeze
      end

      def inspect
        "#<#{self.class.name} #{status}>"
      end
    end

    # Paths with ids.
    #
    # @api private
    module Path
      # What `encodeURIComponent` leaves as it is.
      UNRESERVED = /[^A-Za-z0-9\-_.!~*'()]/
      # An id of spaces only.
      BLANK = /\A[[:space:]]*\z/

      module_function

      # A path from a template with `{}` placeholders, each id percent-encoded.
      #
      #   Path.of("/v1/issuers/{}", issuer_id)
      #
      # Rejects ids that are not Strings or are blank, and `.` and `..`, which URL normalization
      # would turn into the parent path (another resource).
      #
      # @return [String]
      # @raise [Flashpi::Error]
      def of(template, *ids)
        parts = template.split("{}", -1)
        if parts.size != ids.size + 1
          raise ArgumentError,
                "#{template} has #{parts.size - 1} placeholders, not #{ids.size}"
        end

        shown = template.gsub("{}", "{id}")
        path = parts.first.to_s
        ids.each_with_index do |id, index|
          path += encode(segment(id, shown)) + parts.fetch(index + 1)
        end
        path
      end

      # An id as UTF-8 text, checked once converted: not blank (Unicode spaces included, as
      # Python's `strip`), and not `.` or `..` in any encoding.
      #
      # @return [String]
      # @raise [Flashpi::Error]
      def segment(id, shown)
        raise Error, "Missing id in #{shown}: got #{id.inspect}" unless id.is_a?(String)

        text = Validate.utf8(id)
        raise Error, "Invalid id in #{shown}: it is not valid UTF-8 text" if text.nil?
        raise Error, "Missing id in #{shown}: got #{id.inspect}" if BLANK.match?(text)
        raise Error, "Invalid id in #{shown}: #{text.inspect}" if [".", ".."].include?(text)

        text
      end

      # Percent-encodes UTF-8 text as `encodeURIComponent` does.
      #
      # @return [String]
      def encode(text)
        text.gsub(UNRESERVED) { |char| char.unpack("C*").map { |byte| format("%%%02X", byte) }.join }
      end
    end

    # The clock of the requests: monotonic time, sleeping and jitter. Tests replace it.
    #
    # @api private
    module Clock
      module_function

      # @return [Float] monotonic seconds
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # @param seconds [Float]
      def sleep(seconds)
        Kernel.sleep(seconds)
      end

      # @return [Float] a random number in [0, 1)
      def rand
        Random.rand
      end
    end
  end
end
