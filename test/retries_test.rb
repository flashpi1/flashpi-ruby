# frozen_string_literal: true

require_relative "test_helper"

class RetriesTest < Minitest::Test
  include Support

  def issue(api, **)
    api.client.invoices.create({}, **)
  end

  def test_maps_the_status_to_its_class_and_does_not_retry_it
    { 400 => Flashpi::BadRequestError, 401 => Flashpi::AuthenticationError, 403 => Flashpi::PermissionDeniedError,
      404 => Flashpi::NotFoundError, 409 => Flashpi::ConflictError, 422 => Flashpi::UnprocessableEntityError,
      418 => Flashpi::APIError }.each do |status, error_class|
      api = fake_api(problem(status, "some_code"))
      error = assert_raises(error_class) { api.client.status.get }
      assert_equal error_class, error.class
      assert_equal 1, api.sent.size
    end
  end

  def test_treats_a_redirect_as_an_error_without_following_it
    api = fake_api(raw(301, "", { "location" => "https://elsewhere" }))
    error = assert_raises(Flashpi::APIError) { api.client.status.get }
    assert_equal 301, error.status
    assert_equal 1, api.sent.size
  end

  def test_retries_a_500_with_the_same_key_waiting_half_a_second_then_one
    api = fake_api(problem(500, "internal_error"), problem(502, "internal_error"), json_response(document_body, 202))
    assert_equal ID, issue(api)[:id]
    assert_equal 3, api.sent.size
    assert_equal 1, api.sent.map { |attempt| attempt.headers["idempotency-key"] }.uniq.size
    assert_equal 1, api.sent.map(&:content).uniq.size
    assert_equal [0.5, 1.0], api.clock.sleeps
  end

  def test_raises_the_last_error_once_the_retries_run_out
    api = fake_api(*Array.new(3) { problem(503, "service_unavailable") })
    assert_raises(Flashpi::InternalServerError) { api.client.status.get }
    assert_equal 3, api.sent.size
  end

  def test_honors_max_retries_of_the_client_and_of_the_request
    first = fake_api(problem(500, "internal_error"), max_retries: 0)
    assert_raises(Flashpi::InternalServerError) { first.client.status.get }
    assert_equal 1, first.sent.size

    second = fake_api(problem(500, "internal_error"), json_response({}), max_retries: 0)
    assert_equal({}, second.client.status.get(max_retries: 1))
    assert_equal 2, second.sent.size
    assert_raises(Flashpi::Error) { second.client.status.get(max_retries: -1) }
    assert_raises(Flashpi::Error) { second.client.status.get(timeout: 0) }
  end

  def test_retries_network_errors_and_raises_the_last_one
    api = fake_api(network_error, network_error, network_error)
    error = assert_raises(Flashpi::APIConnectionError) { api.client.documents.get(ID) }
    assert_equal "GET https://api.flashpi.com.ec/v1/documents/#{ID} failed: fetch failed", error.message
    assert_equal 3, api.sent.size
  end

  def test_times_out_a_slow_attempt_and_retries_it
    api = fake_api(nil, json_response({ ok: true }), timeout: 1)
    api.transport.instance_variable_get(:@replies)[0] = timeout_after(api.clock, 1)
    assert_equal({ ok: true }, api.client.status.get)
    assert_equal 2, api.sent.size
    assert_equal [0.5], api.clock.sleeps
  end

  def test_raises_a_timeout_error_when_every_attempt_times_out
    api = fake_api(nil, timeout: 2, max_retries: 0)
    api.transport.instance_variable_get(:@replies)[0] = timeout_after(api.clock, 2)
    error = assert_raises(Flashpi::APITimeoutError) { api.client.status.get }
    assert_kind_of Flashpi::APIConnectionError, error
  end

  def test_gives_each_attempt_the_timeout_of_the_client_or_the_request
    api = fake_api(json_response({}), json_response({}), timeout: 7.5)
    api.client.status.get
    api.client.status.get(timeout: 2)
    assert_equal [7.5, 2.0], api.sent.map(&:timeout)
  end

  def test_waits_a_short_retry_after_of_a_429
    api = fake_api(problem(429, "rate_limited", {}, { "retry-after" => "3" }), json_response({}))
    api.client.status.get
    assert_equal 2, api.sent.size
    assert_equal [3.0], api.clock.sleeps
  end

  def test_does_not_wait_for_a_daily_quota_and_reports_when_it_resets
    quota = problem(429, "demo_issuer_quota_exceeded", { limit: 50, resetsAt: "2026-11-13T05:00:00.000Z" },
                    { "retry-after" => "40000" })
    api = fake_api(quota)
    error = assert_raises(Flashpi::RateLimitError) { issue(api) }
    assert_equal 40_000, error.retry_after
    assert_equal 50, error.problem[:limit]
    assert_equal 1, api.sent.size
  end

  # Updating or verifying a webhook endpoint starts a handshake, at most 10 an hour: the 429 asks to
  # wait the rest of the hour, longer than the SDK waits.
  def test_does_not_wait_for_the_hourly_limit_of_webhook_verifications
    [->(client) { client.webhook_endpoints.update(ID, { url: "https://example.com/hooks" }) },
     ->(client) { client.webhook_endpoints.verify(ID) }].each do |call|
      api = fake_api(problem(429, "rate_limited", {}, { "retry-after" => "1800" }))
      error = assert_raises(Flashpi::RateLimitError) { call.call(api.client) }
      assert_equal ["rate_limited", 1800], [error.code, error.retry_after]
      assert_equal 1, api.sent.size
    end
  end

  def test_does_not_retry_the_limit_of_webhook_endpoints
    api = fake_api(problem(409, "webhook_endpoint_limit_reached", { limit: 20 }))
    body = { url: "https://example.com/hooks", events: ["invoice.authorized"] }
    error = assert_raises(Flashpi::ConflictError) { api.client.webhook_endpoints.create(body) }
    assert_equal ["webhook_endpoint_limit_reached", 20], [error.code, error.problem[:limit]]
    assert_equal 1, api.sent.size
  end

  def test_reads_a_retry_after_given_as_an_http_date
    at = (Time.now + 2).httpdate
    api = fake_api(problem(503, "x", {}, { "retry-after" => at }), json_response({}))
    api.client.status.get
    assert_equal 2, api.sent.size
    assert_operator api.clock.sleeps.first, :<=, 3
  end

  def test_retries_a_409_in_progress_after_at_least_a_second
    api = fake_api(problem(409, "idempotency_key_in_progress"),
                   json_response(document_body, 202, { "idempotent-replayed" => "true" }))
    assert_equal ID, issue(api)[:id]
    assert_equal 2, api.sent.size
    assert_equal [1.0], api.clock.sleeps
  end

  def test_waits_for_its_own_earlier_attempt_without_spending_retries
    replies = [network_error] + Array.new(4) do
      problem(409, "idempotency_key_in_progress")
    end + [json_response(document_body)]
    api = fake_api(*replies, max_retries: 1, timeout: 30)
    assert_equal ID, issue(api)[:id]
    assert_equal 6, api.sent.size
    assert_equal [0.5, 1.0, 2.0, 4.0, 5.0], api.clock.sleeps
  end

  def test_stops_waiting_for_its_earlier_attempt_when_the_call_has_no_time_left
    replies = [network_error] + Array.new(5) { problem(409, "idempotency_key_in_progress") }
    api = fake_api(*replies, max_retries: 1, timeout: 4)
    error = assert_raises(Flashpi::ConflictError) { issue(api) }
    assert_equal "idempotency_key_in_progress", error.code
    refute_nil error.idempotency_key
    assert_equal [0.5, 1.0, 2.0], api.clock.sleeps
  end

  def test_does_not_retry_the_missing_demo_certificate
    api = fake_api(problem(503, "demo_issuer_unavailable"))
    assert_raises(Flashpi::InternalServerError) { issue(api) }
    assert_equal 1, api.sent.size
  end

  def test_does_not_retry_a_501
    api = fake_api(raw(501))
    assert_raises(Flashpi::InternalServerError) { api.client.status.get }
    assert_equal 1, api.sent.size
  end

  def test_retries_a_408
    api = fake_api(raw(408), json_response({}))
    assert_equal({}, api.client.status.get)
  end

  def test_caps_the_backoff_at_8_seconds_and_subtracts_up_to_a_quarter_of_jitter
    api = fake_api(*Array.new(6) { problem(500, "internal_error") }, json_response({}), max_retries: 6)
    api.client.status.get
    assert_equal [0.5, 1.0, 2.0, 4.0, 8.0, 8.0], api.clock.sleeps
    jittered = fake_api(problem(500, "internal_error"), json_response({}))
    jittered.clock.random = 0.999
    jittered.client.status.get
    assert_in_delta 0.375, jittered.clock.sleeps.first, 0.001
  end

  def test_retries_patch_and_delete_too
    api = fake_api(network_error, json_response({}), network_error, raw(204))
    assert_equal({}, api.client.issuers.update(ID, { legalName: "x" }))
    assert_nil api.client.issuers.delete(ID)
    assert_equal %i[patch patch delete delete], api.sent.map(&:http_method)
  end

  def test_puts_the_key_on_every_error_of_a_post
    api = fake_api(problem(422, "validation_failed"))
    error = assert_raises(Flashpi::UnprocessableEntityError) { issue(api, idempotency_key: "order-9") }
    assert_equal "order-9", error.idempotency_key
    other = fake_api(network_error, network_error, network_error)
    error = assert_raises(Flashpi::APIConnectionError) { issue(other) }
    assert_equal other.sent.first.headers["idempotency-key"], error.idempotency_key
    get = fake_api(problem(404, "not_found"))
    assert_nil assert_raises(Flashpi::NotFoundError) { get.client.status.get }.idempotency_key
  end

  def test_puts_the_key_on_an_answer_that_is_not_json
    api = fake_api(raw(200, "oops"))
    error = assert_raises(Flashpi::Error) { issue(api, idempotency_key: "k-1") }
    assert_equal "k-1", error.idempotency_key
  end

  def test_returns_the_document_when_a_retry_finds_its_key_used_by_it
    api = fake_api(problem(500, "internal_error"),
                   problem(422, "idempotency_key_reused", { documentId: OTHER_ID }),
                   json_response(document_body(OTHER_ID, "authorized")))
    document = issue(api, language: "es", correlation_id: "order-1")
    assert_equal [OTHER_ID, "authorized"], [document[:id], document[:status]]
    assert_equal(["POST /v1/invoices", "POST /v1/invoices", "GET /v1/documents/#{OTHER_ID}"],
                 api.sent.map { |attempt| "#{attempt.verb} #{attempt.target}" })
    read = api.sent[2].headers
    refute read.key?("idempotency-key")
    assert_equal "es", read["accept-language"]
    assert_equal "order-1", read["x-correlation-id"]
  end

  def test_returns_the_reads_response_with_with_response
    api = fake_api(network_error("reset"), problem(422, "idempotency_key_reused", { documentId: OTHER_ID }),
                   json_response(document_body(OTHER_ID), 200, { "x-request-id" => "req_read" }))
    result = api.client.invoices.with_response.create({})
    assert_equal OTHER_ID, result.data[:id]
    assert_equal "req_read", result.request_id
  end

  def test_keeps_the_calls_key_when_reading_the_recovered_document_fails
    api = fake_api(network_error, problem(422, "idempotency_key_reused", { documentId: OTHER_ID }),
                   problem(404, "not_found"))
    error = assert_raises(Flashpi::NotFoundError) { issue(api, idempotency_key: "order-7") }
    assert_equal "order-7", error.idempotency_key
  end

  def test_raises_the_reuse_on_the_first_attempt
    api = fake_api(problem(422, "idempotency_key_reused", { documentId: OTHER_ID }))
    error = assert_raises(Flashpi::UnprocessableEntityError) { issue(api, idempotency_key: "used-before") }
    assert_equal "idempotency_key_reused", error.code
    assert_equal "used-before", error.idempotency_key
    assert_equal 1, api.sent.size
  end

  def test_raises_a_reuse_without_a_document_id
    [{}, { documentId: "" }, { documentId: 7 }].each do |extra|
      api = fake_api(network_error, problem(422, "idempotency_key_reused", extra))
      assert_raises(Flashpi::UnprocessableEntityError) { issue(api) }
      assert_equal 2, api.sent.size
    end
  end

  def test_does_not_recover_for_other_posts
    api = fake_api(problem(500, "internal_error"), problem(422, "idempotency_key_reused", { documentId: OTHER_ID }))
    assert_raises(Flashpi::UnprocessableEntityError) { api.client.issuers.create({}) }
    assert_equal 2, api.sent.size
  end

  def test_treats_a_delete_404_on_a_retry_as_done
    api = fake_api(network_error("socket hang up"), problem(404, "not_found"))
    result = api.client.issuers.with_response.delete(ID)
    assert_nil result.data
    assert_equal 204, result.status
    refute result.headers.key?("content-type")
    assert_equal "req_problem", result.request_id
    assert_equal 2, api.sent.size
  end

  def test_raises_a_delete_404_on_the_first_attempt
    api = fake_api(problem(404, "not_found"))
    assert_raises(Flashpi::NotFoundError) { api.client.issuers.delete(ID) }
  end

  def test_waits_at_least_the_sync_wait_plus_15_seconds_when_issuing_in_sync_mode
    api = fake_api(json_response(document_body), json_response(document_body), json_response(document_body),
                   json_response(document_body), timeout: 10)
    api.client.invoices.create({ options: { waitForAuthorization: true } })
    api.client.invoices.create({ options: { waitForAuthorization: true, waitTimeoutSeconds: 30 } })
    api.client.invoices.create({ "options" => { "waitForAuthorization" => true, "waitTimeoutSeconds" => "x" } })
    api.client.invoices.create({ options: { waitForAuthorization: false } }, timeout: 5)
    assert_equal [30.0, 45.0, 30.0, 5.0], api.sent.map(&:timeout)
  end
end
