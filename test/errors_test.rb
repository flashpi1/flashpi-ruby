# frozen_string_literal: true

require_relative "test_helper"

class ErrorsTest < Minitest::Test
  include Support

  def error(status, body, headers = {})
    Flashpi::Internal::Problems.error(status, headers, body)
  end

  def test_each_status_gets_its_class
    assert_instance_of Flashpi::RateLimitError, error(429, "")
    assert_instance_of Flashpi::InternalServerError, error(504, "")
    assert_instance_of Flashpi::APIError, error(418, "")
  end

  def test_reads_the_problem_details_and_their_extensions
    body = JSON.generate({ code: "validation_failed", title: "Validation failed", detail: "Bad fields",
                           errors: [{ field: "items[0].quantity", code: "required", message: "Required" }],
                           requestId: "req_9", expectedTotal: "1.15" })
    failure = error(422, body)
    assert_equal "validation_failed", failure.code
    assert_equal "Validation failed", failure.title
    assert_equal "Bad fields", failure.detail
    assert_equal "items[0].quantity", failure.errors.first[:field]
    assert_equal "req_9", failure.request_id
    assert_equal "1.15", failure.problem[:expectedTotal]
    assert_equal "422 validation_failed: Bad fields", failure.message
  end

  def test_knows_the_codes_of_the_contract
    failure = error(403, JSON.generate({ code: "live_key_required" }))
    assert_instance_of Flashpi::PermissionDeniedError, failure
    assert_equal "live_key_required", failure.code
    body = JSON.generate({ code: "validation_failed",
                           errors: [{ field: "items[0].additionalDetails", code: "demo_issuer_free_text_not_allowed",
                                      message: "Not allowed" }] })
    assert_equal "demo_issuer_free_text_not_allowed", error(422, body).errors.first[:code]
    assert typed?(%w[live_key_required webhook_endpoint_limit_reached], "::Array[::Flashpi::Types::error_code]")
    assert typed?(%w[certificate_ruc_missing demo_issuer_description_too_long demo_issuer_free_text_not_allowed],
                  "::Array[::Flashpi::Types::field_error_code]")
    assert typed?(%w[certificate_ruc_mismatch sri_authorization_mismatch],
                  "::Array[::Flashpi::Types::document_failure_code]")
    refute typed?("no_such_code", "::Flashpi::Types::error_code")
    # An unknown code still reads: the SDK's own code types accept any String.
    assert typed?("no_such_code", "::Flashpi::Types::api_error_code")
  end

  def test_falls_back_to_the_title_and_the_header_request_id
    failure = error(409, JSON.generate({ code: "conflict", title: "Conflict", errors: "nope" }),
                    { "x-request-id" => "req_header" })
    assert_equal "409 conflict: Conflict", failure.message
    assert_equal "req_header", failure.request_id
    assert_empty failure.errors
    assert_equal "400 bad", error(400, JSON.generate({ code: "bad" })).message
  end

  def test_describes_bodies_that_are_not_problem_details
    assert_equal "502 <html> Bad gateway </html>", error(502, "<html>\n  Bad   gateway\n</html>").message
    assert_equal "503 (no response body)", error(503, "").message
    assert_nil error(500, JSON.generate({ code: 7 })).problem
    assert_nil error(500, "[1]").problem
    assert_nil error(500, "{").problem
    assert_equal 200 + 4, error(500, "x" * 300).message.length
    assert_nil error(500, "#{"[" * 600}#{"]" * 600}").problem
  end

  def test_reads_retry_after_in_seconds_or_as_a_date
    retry_after = Flashpi::Internal::Problems.method(:retry_after)
    now = Time.utc(2026, 11, 13, 10, 0, 0).to_f
    assert_equal 120, retry_after.call(" 120 ", now)
    assert_equal 10**18, retry_after.call("9" * 30, now)
    assert_equal 30, retry_after.call("Fri, 13 Nov 2026 10:00:30 GMT", now)
    assert_equal 0, retry_after.call("Fri, 13 Nov 2026 09:00:00 GMT", now)
    assert_equal 60, retry_after.call("2026-11-13T10:01:00Z", now)
    assert_equal 60, retry_after.call("2026-11-13T10:01:00", now)
    assert_equal 0, retry_after.call("2026-11-13", now)
    assert_nil retry_after.call("soon", now)
    assert_nil retry_after.call("-5", now)
    assert_nil retry_after.call(nil, now)
  end

  def test_reads_retry_after_against_the_clock
    failure = error(429, "", { "retry-after" => (Time.now + 30).httpdate })
    assert_includes 28..31, failure.retry_after
  end

  def test_survive_marshal_with_their_key
    failure = error(422, JSON.generate({ code: "validation_failed" }))
    failure.idempotency_key = "k"
    copy = Marshal.load(Marshal.dump(failure))
    assert_equal [422, "validation_failed", "k"], [copy.status, copy.code, copy.idempotency_key]
    verification = Marshal.load(Marshal.dump(Flashpi::WebhookVerificationError.new(:invalid_secret, "x")))
    assert_equal :invalid_secret, verification.reason
  end

  def test_every_error_is_a_flashpi_error
    [Flashpi::APIError, Flashpi::APIConnectionError, Flashpi::APITimeoutError,
     Flashpi::WebhookVerificationError].each do |klass|
      assert_operator klass, :<, Flashpi::Error
    end
    assert_operator Flashpi::Error, :<, StandardError
  end
end
