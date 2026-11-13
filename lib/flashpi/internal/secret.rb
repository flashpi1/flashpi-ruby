# frozen_string_literal: true

module Flashpi
  module Internal
    # A value that must never be shown: an API key, a .p12 and its password.
    #
    # The value lives in a closure, not in an instance variable, so `inspect`, `pp`, `to_s`,
    # ActiveSupport's `as_json` (which reads instance variables) and `Marshal.dump` (which refuses
    # a Proc) never reveal it. {#reveal} is the only way to read it.
    #
    # @api private
    class Secret
      # @param value [Object]
      def initialize(value)
        @reader = -> { value }
        freeze
      end

      # @return [Object] the value
      def reveal
        @reader.call
      end

      # @return [String]
      def inspect
        "#<#{self.class.name} [FILTERED]>"
      end
      alias to_s inspect

      # @raise [TypeError] always: a secret is never serialized.
      def marshal_dump
        raise TypeError, "A Flashpi secret cannot be serialized"
      end

      # @raise [TypeError] always: a secret is never serialized.
      def _dump(_level)
        raise TypeError, "A Flashpi secret cannot be serialized"
      end
    end
  end
end
