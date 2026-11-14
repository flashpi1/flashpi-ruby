# frozen_string_literal: true

module Flashpi
  # Verification of the webhooks Flashpi sends (Standard Webhooks). It needs no API key, and is
  # also available as `client.webhooks`.
  #
  # A webhook is signed with HMAC-SHA256 over `webhook-id.webhook-timestamp.body` using the
  # endpoint's `whsec_` secret. During a secret rotation Flashpi signs with both secrets, so the
  # `webhook-signature` header lists several signatures.
  #
  #   event = Flashpi::Webhooks.unwrap(request.raw_post, request.headers, ENV.fetch("FLASHPI_WEBHOOK_SECRET"))
  #   case event[:type]
  #   when "webhook_endpoint.verification" then render json: { challenge: event[:data][:challenge] }
  #   when "invoice.authorized" then ...
  #   end
  #
  # Error trackers can record the local variables of the method that raises, so every
  # verification error is raised by a method that holds neither the secret, its key nor the
  # expected signature.
  module Webhooks
    # Default largest gap, in seconds, between a webhook's timestamp and the receiver's clock.
    TOLERANCE_SECONDS = 300

    SECRET_PREFIX = "whsec_"
    # Key sizes of a Standard Webhooks secret (Flashpi makes 32-byte keys).
    MIN_SECRET_BYTES = 24
    MAX_SECRET_BYTES = 64
    SIGNATURE_BYTES = 32
    TIMESTAMP = /\A[0-9]{1,12}\z/
    BASE64 = %r{\A[A-Za-z0-9+/]*={0,2}\z}
    NO_MATCH = "No webhook-signature matches the body and the secret"

    class << self
      # Checks that a webhook comes from Flashpi and is recent.
      #
      # Raises a {WebhookVerificationError} otherwise: answer 400 and ignore the request. Pass the
      # raw body exactly as received; a body parsed and serialized again does not match.
      #
      # @param payload [String] the raw body
      # @param headers [Hash, #each] the request headers: a Hash in any letter case, a Rack env
      #   (`HTTP_WEBHOOK_ID`) or Rails' `request.headers`; repeated headers may come as Arrays
      # @param secret [String] the endpoint's signing secret (`whsec_...`)
      # @param tolerance [Integer, Float, nil] largest gap, in seconds, between
      #   `webhook-timestamp` and now (default 300)
      # @param now [Time, Integer, Float, nil] the current time, for tests: a Time or Unix seconds
      # @return [nil]
      # @raise [WebhookVerificationError]
      # @raise [TypeError, ArgumentError] for a bad `tolerance` or `now`
      def verify_signature(payload, headers, secret, tolerance: nil, now: nil)
        tolerance_seconds, now_seconds = verify_options(tolerance, now)
        key = signing_key(secret)
        webhook_id = header(headers, "webhook-id")
        timestamp = header(headers, "webhook-timestamp")
        signatures = header(headers, "webhook-signature")
        if webhook_id.nil? || timestamp.nil? || signatures.nil?
          reject!(:missing_headers, "The webhook-id, webhook-timestamp and webhook-signature headers are required")
        end
        reject!(:invalid_timestamp, "The webhook-timestamp is not valid") unless TIMESTAMP.match?(timestamp)
        # Written so that anything unexpected fails closed.
        unless (now_seconds.floor - timestamp.to_i).abs <= tolerance_seconds
          reject!(:timestamp_out_of_range,
                  "The webhook-timestamp is more than #{shown(tolerance_seconds)} seconds away from now")
        end

        body = payload_bytes(payload)
        reject!(:no_matching_signature, NO_MATCH) unless signed?(key, "#{webhook_id.b}.#{timestamp}.".b + body,
                                                                 signatures)
        nil
      end

      # Verifies a webhook (see {verify_signature}) and returns its parsed body, with Symbol keys.
      #
      # Branch on `event[:type]`. Endpoints in thin mode receive no `data`: read the event with
      # `client.events.get(event[:id])`.
      #
      # @return [Hash{Symbol => Object}] the event
      # @raise [WebhookVerificationError]
      def unwrap(payload, headers, secret, tolerance: nil, now: nil)
        verify_signature(payload, headers, secret, tolerance:, now:)
        event = parse(payload)
        reject!(:invalid_payload, "The webhook body is not a JSON object") unless event.is_a?(Hash)

        _ = event
      end

      private

      def parse(payload)
        Internal::JSONText.parse(Internal::JSONText.decode(payload.b))
      rescue Internal::JSONText::Invalid
        reject!(:invalid_payload, "The webhook body is not JSON")
      end

      # Raises from a frame that holds only the reason.
      def reject!(reason, message)
        raise WebhookVerificationError.new(reason, message)
      end

      # A header without letter case, or in a Rack env's form (`HTTP_WEBHOOK_ID`). Repeated
      # headers: signature lists are joined, otherwise the first. An empty value is missing. Names
      # and values are read as bytes (as Rack servers give them), so no encoding of theirs can
      # make the checks below raise anything but a WebhookVerificationError.
      def header(headers, name)
        unless headers.respond_to?(:each)
          raise TypeError, "headers must be a Hash (or Rack env, or Rails request.headers), not #{headers.class}"
        end

        env_name = "HTTP_#{name.upcase.tr("-", "_")}"
        values = [] #: Array[String]
        headers.each do |key, value|
          next unless key.is_a?(String) || key.is_a?(Symbol)

          field = key.to_s.b
          next unless field.casecmp?(name) || field == env_name

          values << value.b if value.is_a?(String)
          values.concat(value.grep(String).map(&:b)) if value.is_a?(Array)
        end
        found = name == "webhook-signature" ? values.join(" ") : values.first
        found.nil? || found.empty? ? nil : found
      end

      # The decoded key of a `whsec_` secret, in a {Internal::Secret}.
      def signing_key(secret)
        unless secret.is_a?(String) && !secret.b.strip.empty?
          reject!(:invalid_secret,
                  "The webhook secret is empty: copy it from the console or webhook_endpoints.get_secret")
        end

        size = key_size(secret)
        if size.zero?
          reject!(:invalid_secret, "The webhook secret is not a whsec_ secret (base64 after the prefix)")
        elsif size < MIN_SECRET_BYTES || size > MAX_SECRET_BYTES
          reject!(:invalid_secret, "The webhook secret is not a complete whsec_ secret: copy it again from the " \
                                   "console or webhook_endpoints.get_secret")
        end
        Internal::Secret.new(decode_base64(encoded_key(secret)) || "")
      end

      # The size of a secret's key, or 0 when it is not base64. It returns instead of raising, so
      # the key never stays in the frame of an error.
      def key_size(secret)
        key = decode_base64(encoded_key(secret))
        key ? key.bytesize : 0
      end

      # The base64 after the prefix, read as bytes.
      def encoded_key(secret)
        secret.b.strip.delete_prefix(SECRET_PREFIX)
      end

      # Whether a v1 signature of the header signs `message`. The signatures are read before the
      # expected one is computed, and nothing after that can raise, so the expected signature
      # never stays in the frame of an error.
      def signed?(key, message, signatures)
        candidates = v1_signatures(signatures)
        expected = OpenSSL::HMAC.digest("SHA256", key.reveal, message)
        candidates.any? { |signature| OpenSSL.fixed_length_secure_compare(signature, expected) }
      end

      # The decoded v1 signatures of a `webhook-signature` header that have the right size.
      def v1_signatures(signatures)
        signatures.b.split(/ /).filter_map do |entry|
          version, comma, encoded = entry.partition(",")
          next if comma.empty? || version != "v1"

          signature = decode_base64(encoded)
          signature if signature && signature.bytesize == SIGNATURE_BYTES
        end
      end

      # Standard base64 to bytes, or nil when it is not base64 (padding optional, like atob).
      def decode_base64(value)
        return nil unless BASE64.match?(value) && value.length % 4 != 1

        data = (value.length % 4).zero? ? value.sub(/=+\z/, "") : value
        return nil if data.include?("=") || data.length % 4 == 1

        # Only the alphabet is left, in a length that decodes once padded.
        "#{data}#{"=" * (-data.length % 4)}".unpack1("m").to_s
      end

      def payload_bytes(payload)
        unless payload.is_a?(String)
          reject!(:invalid_payload,
                  "Pass the raw webhook body as a String (not parsed JSON)")
        end

        payload.b
      end

      # The checked tolerance and clock. Bad values are programming errors: TypeError or
      # ArgumentError, never a skipped time check.
      def verify_options(tolerance, now)
        value = tolerance.nil? ? TOLERANCE_SECONDS : tolerance
        unless value.is_a?(Integer) || value.is_a?(Float)
          raise TypeError,
                "tolerance must be a number of seconds, 0 or more"
        end
        raise ArgumentError, "tolerance must be a number of seconds, 0 or more" unless value.to_f.finite? && value >= 0

        [value.to_f, clock(now)]
      end

      def clock(now)
        seconds = case now
                  when nil then Time.now.to_f
                  when Time then now.to_f
                  when Integer then now.bit_length > 1000 ? Float::INFINITY : now.to_f
                  when Float then now
                  else raise TypeError, "now must be a Time or a number of Unix seconds"
                  end
        raise ArgumentError, "now must be a Time or a number of Unix seconds" unless seconds.finite?

        seconds
      end

      def shown(seconds)
        seconds == seconds.floor ? seconds.to_i.to_s : seconds.to_s
      end
    end
  end
end
