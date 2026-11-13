# frozen_string_literal: true

module Flashpi
  module Internal
    # JSON in and out: request bodies serialized once, answers parsed with Symbol keys.
    #
    # @api private
    module JSONText
      # A body that is not JSON.
      class Invalid < StandardError; end

      MAX_NESTING = 512

      module_function

      # Compact UTF-8 JSON of a request body, like `JSON.stringify`.
      #
      # The body may hold Hashes (String, Symbol or Integer keys), Arrays, Strings, Symbols,
      # Integers, finite Floats, true, false and nil. Anything else is refused before anything is
      # sent: amounts and dates are text in the Flashpi API.
      #
      # @return [String]
      # @raise [TypeError] for a value JSON has no counterpart for
      # @raise [ArgumentError] for NaN or infinite numbers, text that is not valid UTF-8, a key
      #   given twice or a Hash or Array that contains itself
      def encode(body)
        JSON.generate(plain(body, {}), max_nesting: false)
      end

      # Parses JSON text with Symbol keys.
      #
      # @return [Object]
      # @raise [Invalid] when the text is not JSON
      def parse(text)
        JSON.parse(text, symbolize_names: true, max_nesting: MAX_NESTING)
      rescue JSON::ParserError, EncodingError, ArgumentError => e
        raise Invalid, e.class.name
      end

      # UTF-8 text from bytes, with invalid sequences replaced (like the Node SDK's TextDecoder).
      #
      # @return [String]
      def decode(bytes)
        bytes.dup.force_encoding(Encoding::UTF_8).scrub("�")
      end

      # @api private
      def plain(value, seen)
        case value
        when Hash then plain_hash(value, seen)
        when Array then nested(value, seen) { value.map { |item| plain(item, seen) } }
        when String then text(value)
        when Symbol then text(value.to_s)
        when Integer, true, false, nil then value
        when Float
          raise ArgumentError, "The body has a number JSON cannot hold (NaN or infinite)" unless value.finite?

          value
        else
          raise TypeError, "The body must hold only Hashes, Arrays, Strings, numbers, booleans and nil, " \
                           "not #{value.class} (amounts and dates are Strings)"
        end
      end

      # @api private
      def plain_hash(hash, seen)
        nested(hash, seen) do
          hash.each_with_object({}) do |(key, item), result|
            name = key_text(key)
            raise ArgumentError, "The body has the key #{name.inspect} twice" if result.key?(name)

            result[name] = plain(item, seen)
          end
        end
      end

      # @api private
      def key_text(key)
        case key
        when String then text(key)
        when Symbol, Integer then text(key.to_s)
        else raise TypeError, "The keys of the body must be Strings or Symbols, not #{key.class}"
        end
      end

      # @api private
      def nested(container, seen)
        id = container.object_id
        raise ArgumentError, "The body contains itself" if seen.key?(id)

        seen[id] = true
        result = yield
        seen.delete(id)
        result
      end

      # @api private
      def text(value)
        utf8 = Validate.utf8(value)
        raise ArgumentError, "The body has text that is not valid UTF-8" if utf8.nil?

        utf8
      end
    end
  end
end
