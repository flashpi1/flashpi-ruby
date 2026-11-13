# frozen_string_literal: true

module Flashpi
  # Every error this gem raises extends this class, except for invalid arguments (`ArgumentError`
  # and `TypeError`, as for any Ruby method).
  class Error < StandardError
    # The Idempotency-Key a failed POST used (the caller's or the one the SDK made), or nil. To try
    # the same operation again later without issuing twice, pass it back:
    # `create(body, idempotency_key: error.idempotency_key)`.
    attr_accessor :idempotency_key
  end

  # The API answered with an error status.
  #
  # Branch on {#code} (stable English slugs such as `validation_failed`), never on {#message},
  # which follows the requested language.
  class APIError < Error
    # @return [Integer] HTTP status of the answer.
    attr_reader :status

    # @return [String, nil] Error code, or nil when the answer had no Problem Details (a 502).
    attr_reader :code

    # @return [String, nil] Short summary of the problem type.
    attr_reader :title

    # @return [String, nil] What went wrong in this request.
    attr_reader :detail

    # @return [Array<Hash{Symbol => Object}>] Field-level problems of a request body or query.
    attr_reader :errors

    # @return [String, nil] Flashpi's id of the request (`x-request-id`): share it with support.
    attr_reader :request_id

    # @return [Hash{Symbol => Object}, nil] The full Problem Details body, with its extension
    #   members (`documentId`, `limit`, `resetsAt`, ...), when there was one.
    attr_reader :problem

    # @return [Hash{String => String}] Response headers, by lowercase name.
    attr_reader :headers

    # @param status [Integer]
    # @param headers [Hash{String => String}] by lowercase name
    # @param problem [Hash{Symbol => Object}, nil]
    # @param body_text [String]
    def initialize(status, headers, problem, body_text = "")
      super(Internal::Problems.message(status, problem, body_text))
      @status = status
      @headers = headers
      @problem = problem
      members = problem || {}
      @code = Internal::Problems.text(members[:code])
      @title = Internal::Problems.text(members[:title])
      @detail = Internal::Problems.text(members[:detail])
      errors = members[:errors]
      @errors = errors.is_a?(Array) ? errors : []
      @request_id = Internal::Problems.text(members[:requestId]) || headers["x-request-id"]
    end

    # Seconds the API asked to wait before trying again (`Retry-After`), or nil.
    #
    # Daily quota errors point at the next midnight in Ecuador, so this can be hours.
    #
    # @return [Integer, nil]
    def retry_after
      Internal::Problems.retry_after(headers["retry-after"])
    end
  end

  # 400: the request could not be read (malformed JSON, invalid Idempotency-Key, ...).
  class BadRequestError < APIError; end

  # 401: the API key is missing, malformed, unknown or revoked.
  class AuthenticationError < APIError; end

  # 403: the key may not do this (read-only, another issuer, IP allowlist, suspended account).
  class PermissionDeniedError < APIError; end

  # 404: the resource does not exist in this mode (test or live) for this account.
  class NotFoundError < APIError; end

  # 409: the request conflicts with the current state (sequential used, RIDE not ready, ...).
  class ConflictError < APIError; end

  # 422: the request is well formed but invalid (`validation_failed`, `total_mismatch`, ...).
  class UnprocessableEntityError < APIError; end

  # 429: a limit was reached; see {#retry_after} and the `limit` and `resetsAt` members.
  class RateLimitError < APIError; end

  # 5xx: Flashpi failed to answer. Requests are retried automatically before this is raised.
  class InternalServerError < APIError; end

  # The request never got an answer (DNS, TLS, connection reset, ...).
  class APIConnectionError < Error; end

  # The request took longer than the `timeout` option.
  class APITimeoutError < APIConnectionError; end

  # A webhook did not come from Flashpi, was altered, or is too old: answer 400 and ignore it.
  class WebhookVerificationError < Error
    # Why it was rejected: `:missing_headers`, `:invalid_timestamp`, `:timestamp_out_of_range`,
    # `:no_matching_signature`, `:invalid_secret` or `:invalid_payload`.
    #
    # @return [Symbol]
    attr_reader :reason

    # @param reason [Symbol]
    # @param message [String]
    def initialize(reason, message)
      super(message)
      @reason = reason
    end
  end
end
