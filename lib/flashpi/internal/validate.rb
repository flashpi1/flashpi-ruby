# frozen_string_literal: true

module Flashpi
  module Internal
    # Checks of the settings, shared by the client and every request.
    #
    # Header names and values are checked by the SDK itself before anything is sent, so a bad one
    # is never retried as a network failure. Messages never show a value, which may be a secret.
    #
    # @api private
    module Validate
      # The longest timeout, in seconds: the Node SDK's limit (2147483647 ms), so every SDK accepts
      # the same values.
      MAX_TIMEOUT = 2_147_483.647

      # A header name (RFC 9110 `token`).
      TOKEN = /\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/

      # Trimmed from both ends of a header value, as the Fetch standard's `Headers` does.
      AROUND = /\A[ \t\r\n]+|[ \t\r\n]+\z/

      # What HTTP refuses inside a header value: control characters other than the tab.
      CONTROL = /[\x00-\x08\x0a-\x1f\x7f]/

      # Headers net/http sets from the body: another value would frame the body wrongly.
      FRAMING = %w[content-length transfer-encoding].freeze

      module_function

      # A timeout in seconds: more than 0 and at most {MAX_TIMEOUT}.
      #
      # @return [Float]
      # @raise [Flashpi::Error]
      def timeout!(name, value)
        unless (value.is_a?(Integer) || value.is_a?(Float)) && value.positive? && value <= MAX_TIMEOUT
          raise Error, "#{name} must be more than 0 and at most #{MAX_TIMEOUT} seconds"
        end

        value.to_f
      end

      # A number of retries: a whole number, 0 or more.
      #
      # @return [Integer]
      # @raise [Flashpi::Error]
      def retries!(name, value)
        raise Error, "#{name} must be a whole number, 0 or more" unless value.is_a?(Integer) && value >= 0

        value
      end

      # A header name: an RFC 9110 token, as a String or a Symbol.
      #
      # @return [String]
      # @raise [TypeError] when it is not text
      # @raise [ArgumentError] when it is not a token
      def header_name!(name)
        text = name.is_a?(Symbol) ? name.to_s : name
        raise TypeError, "Header names must be String or Symbol, not #{name.class}" unless text.is_a?(String)
        raise ArgumentError, "#{text.inspect} is not a valid header name" unless TOKEN.match?(text)

        text
      end

      # A header value without the spaces, tabs and line breaks around it, as the Node SDK's
      # `Headers` sends it, in UTF-8.
      #
      # @return [String]
      # @raise [TypeError] when it is not a String
      # @raise [ArgumentError] when a line break or another control character other than a tab is
      #   left, or when it is not valid text
      def header_value!(label, value)
        raise TypeError, "#{label} must be a String, not #{value.class}" unless value.is_a?(String)

        text = utf8(value)
        raise ArgumentError, "#{label} has a character that cannot be sent as UTF-8" if text.nil?

        trimmed = text.gsub(AROUND, "")
        raise ArgumentError, "#{label} has a line break or another control character" if CONTROL.match?(trimmed)

        trimmed
      end

      # The headers of a Hash, each name and value checked. Content-Length and Transfer-Encoding
      # are refused: net/http sets them from the body.
      #
      # @return [Hash{String => String}]
      def headers!(label, headers)
        return {} if headers.nil?
        raise TypeError, "#{label} must be a Hash of header names to values" unless headers.is_a?(Hash)

        checked = {} #: Hash[String, String]
        headers.each do |name, value|
          valid = header_name!(name)
          if FRAMING.include?(valid.downcase)
            raise ArgumentError,
                  "#{valid.inspect} is set by the SDK from the body: leave it out"
          end

          checked[valid] = header_value!("The value of header #{valid.inspect}", value)
        end
        checked
      end

      # The text as valid UTF-8, or nil when it cannot be. Binary strings are read as UTF-8.
      #
      # @return [String, nil]
      def utf8(text)
        if [Encoding::BINARY, Encoding::UTF_8].include?(text.encoding)
          copy = text.dup.force_encoding(Encoding::UTF_8)
          copy.valid_encoding? ? copy : nil
        elsif !text.valid_encoding?
          nil
        else
          text.encode(Encoding::UTF_8)
        end
      rescue EncodingError
        nil
      end
    end
  end
end
