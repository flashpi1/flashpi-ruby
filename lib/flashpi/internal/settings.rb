# frozen_string_literal: true

module Flashpi
  module Internal
    # The settings of a client, checked before anything is sent.
    #
    # @api private
    module Settings
      # What an API key is made of: visible ASCII, without spaces.
      API_KEY_CHARACTERS = /\A[\x21-\x7e]+\z/
      # What JavaScript's `trim()` removes around a string, the Node SDK's key included: its white
      # space and line breaks, and the byte order mark (U+FEFF).
      JS_SPACE = "[\t\n\v\f\r    -     　﻿]"
      AROUND = /\A#{JS_SPACE}+|#{JS_SPACE}+\z/o

      module_function

      # The checked settings. The key is checked first, so a missing or bad key is the error
      # reported, and every error is raised by a method that holds no copy of the key (error
      # trackers can record the local variables of the method that raises).
      def configure(api_key, base_url:, timeout:, max_retries:, language:, default_headers:)
        problem = key_problem(trimmed_key(api_key))
        refuse!(problem) if problem
        headers = Internal::Validate.headers!("default_headers", default_headers)
        language = Internal::Validate.header_value!("language", language.is_a?(Symbol) ? language.to_s : language) unless language.nil?
        if headers.keys.any? { |name| name.casecmp?("idempotency-key") }
          refuse!("default_headers cannot carry an Idempotency-Key: it must be unique per operation. " \
                  "Pass idempotency_key: to each create instead")
        end
        url = base_url.nil? ? DEFAULT_BASE_URL : base_url
        refuse!("base_url must be an http:// or https:// URL, got #{url.inspect}") unless http_url?(url)

        Internal::ClientConfig.new(
          api_key: trimmed_key(api_key),
          base_url: url,
          timeout: Internal::Validate.timeout!("timeout", timeout.nil? ? DEFAULT_TIMEOUT : timeout),
          max_retries: Internal::Validate.retries!("max_retries", max_retries.nil? ? DEFAULT_MAX_RETRIES : max_retries),
          language:,
          default_headers: headers
        )
      end

      def refuse!(message)
        raise Error, message
      end

      def http_url?(url)
        return false unless url.is_a?(String)

        parsed = URI.parse(url)
        %w[http https].include?(parsed.scheme) && !parsed.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end

      # The key: the argument or FLASHPI_API_KEY, trimmed as JavaScript's `trim()`, the byte order
      # mark included. Anything that is not a String is no key.
      def trimmed_key(api_key)
        value = api_key.nil? ? ENV.fetch("FLASHPI_API_KEY", nil) : api_key
        return "" unless value.is_a?(String)

        text = Internal::Validate.utf8(value)
        # A key that is not valid text is refused for its characters below.
        text ? text.gsub(AROUND, "") : value.b
      end

      # Why a trimmed key cannot be used, or nil. It returns instead of raising, so its frame is
      # never part of an error.
      def key_problem(key)
        if key.empty?
          "Missing API key: pass it to Flashpi::Client.new(api_key: ...) or set the FLASHPI_API_KEY " \
            "environment variable"
        elsif key.start_with?("whsec_")
          "That is a webhook signing secret (whsec_...), not an API key: use it with Flashpi::Webhooks"
        elsif !key.start_with?("fp_test_", "fp_live_")
          "The API key must start with fp_test_ or fp_live_"
        elsif !API_KEY_CHARACTERS.match?(key)
          # Never the key: net/http would refuse it in the Authorization header and quote it.
          "The API key has spaces, line breaks or other characters an API key cannot have: copy it again " \
            "from the Flashpi console"
        end
      end
    end
  end
end
