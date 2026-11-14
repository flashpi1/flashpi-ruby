# frozen_string_literal: true

module Flashpi
  module Internal
    # Reading the error answers of the API (RFC 9457 Problem Details) and their Retry-After.
    #
    # @api private
    module Problems
      # The error class of each status; other 5xx are InternalServerError, the rest APIError.
      ERROR_CLASSES = {
        400 => BadRequestError,
        401 => AuthenticationError,
        403 => PermissionDeniedError,
        404 => NotFoundError,
        409 => ConflictError,
        422 => UnprocessableEntityError,
        429 => RateLimitError
      }.freeze

      DELTA_SECONDS = /\A[0-9]+\z/
      # Longer digit strings are past any useful wait.
      MAX_DELTA_DIGITS = 18
      MAX_DELTA = 1_000_000_000_000_000_000
      TIME_ZONE = /(?:Z|[+-][0-9]{2}(?::?[0-9]{2})?)\z/i

      module_function

      # The error that matches the status of an answer.
      #
      # @param status [Integer]
      # @param headers [Hash{String => String}]
      # @param body_text [String]
      # @return [Flashpi::APIError]
      def error(status, headers, body_text)
        error_class = ERROR_CLASSES.fetch(status) { status >= 500 ? InternalServerError : APIError }
        error_class.new(status, headers, parse(body_text), body_text)
      end

      # The Problem Details of a body: a JSON object whose `code` is a String, or nil (an answer
      # from the edge, such as a CDN or a firewall, is not one).
      #
      # @return [Hash{Symbol => Object}, nil]
      def parse(body_text)
        return nil if body_text.empty?

        parsed = JSONText.parse(body_text)
        parsed.is_a?(Hash) && parsed[:code].is_a?(String) ? parsed : nil
      rescue JSONText::Invalid
        nil
      end

      # The message of an error answer.
      #
      # @return [String]
      def message(status, problem, body_text)
        if problem
          detail = text(problem[:detail]) || text(problem[:title])
          return detail ? "#{status} #{problem[:code]}: #{detail}" : "#{status} #{problem[:code]}"
        end
        excerpt = body_text.split(/[[:space:]]+/).reject(&:empty?).join(" ")[0, 200] || ""
        excerpt.empty? ? "#{status} (no response body)" : "#{status} #{excerpt}"
      end

      # @return [String, nil] the value when it is a String
      def text(value)
        value.is_a?(String) ? value : nil
      end

      # Seconds from a `Retry-After` value (delta-seconds or an HTTP date), or nil.
      #
      # @param value [String, nil]
      # @param now [Float] the current Unix time in seconds
      # @return [Integer, nil]
      def retry_after(value, now = Time.now.to_f)
        return nil unless value.is_a?(String)

        trimmed = value.strip
        if DELTA_SECONDS.match?(trimmed)
          return trimmed.length <= MAX_DELTA_DIGITS ? trimmed.to_i : MAX_DELTA
        end

        moment = date(trimmed)
        moment && [0, (moment - now).ceil].max
      end

      # Unix seconds of an HTTP date (or an ISO 8601 one, UTC when it has no zone), or nil.
      #
      # @return [Float, nil]
      def date(value)
        Time.httpdate(value).to_f
      rescue ArgumentError
        begin
          Time.rfc2822(value).to_f
        rescue ArgumentError
          iso8601(value)
        end
      end

      # @return [Float, nil]
      def iso8601(value)
        if /\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/.match?(value)
          parts = value.split("-").map(&:to_i)
          return Time.utc(parts.fetch(0), parts.fetch(1), parts.fetch(2)).to_f
        end
        Time.iso8601(TIME_ZONE.match?(value) ? value : "#{value}Z").to_f
      rescue ArgumentError
        nil
      end
    end
  end
end
