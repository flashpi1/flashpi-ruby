# frozen_string_literal: true

require_relative "test_helper"

class ClientTest < Minitest::Test
  include Support

  def with_env(name, value)
    previous = ENV.fetch(name, nil)
    value.nil? ? ENV.delete(name) : ENV.store(name, value)
    yield
  ensure
    previous.nil? ? ENV.delete(name) : ENV.store(name, previous)
  end

  def test_takes_the_key_and_tells_the_environment_from_its_prefix
    assert_equal "test", Flashpi::Client.new(api_key: TEST_KEY).environment
    assert_equal "live", Flashpi::Client.new(api_key: LIVE_KEY).environment
  end

  def test_falls_back_to_the_environment_variable
    with_env("FLASHPI_API_KEY", LIVE_KEY) do
      assert_equal "live", Flashpi::Client.new.environment
    end
  end

  def test_refuses_a_missing_key
    with_env("FLASHPI_API_KEY", nil) do
      error = assert_raises(Flashpi::Error) { Flashpi::Client.new }
      assert_includes error.message, "Missing API key"
      ["", "   ", 42].each do |key|
        assert_raises(Flashpi::Error) { Flashpi::Client.new(api_key: key) }
      end
    end
  end

  def test_refuses_a_webhook_secret_or_another_prefix
    error = assert_raises(Flashpi::Error) { Flashpi::Client.new(api_key: "whsec_abc") }
    assert_includes error.message, "webhook signing secret"
    error = assert_raises(Flashpi::Error) { Flashpi::Client.new(api_key: "sk_test_abc") }
    assert_includes error.message, "must start with fp_test_ or fp_live_"
  end

  def test_refuses_a_key_with_characters_a_key_cannot_have_without_showing_it
    ["fp_test_a b", "fp_test_ab\ncd", "fp_test_aéb", "fp_test_a\x00b", "fp_test_a\xff".b,
     "fp_test_a\xff"].each do |key|
      error = assert_raises(Flashpi::Error) { Flashpi::Client.new(api_key: key) }
      assert_includes error.message, "copy it again"
      refute_includes error.message, "fp_test_a"
    end
  end

  def test_refuses_such_a_key_from_the_environment_variable
    with_env("FLASHPI_API_KEY", "fp_live_with space") do
      assert_raises(Flashpi::Error) { Flashpi::Client.new }
    end
  end

  def test_trims_what_javascripts_trim_removes_around_a_key
    api = fake_api(json_response({}), api_key: "﻿  #{TEST_KEY}\r\n\t")
    api.client.status.get
    assert_equal "Bearer #{TEST_KEY}", api.sent.first.headers["authorization"]
  end

  def test_trims_a_byte_order_mark_around_the_environment_variable
    with_env("FLASHPI_API_KEY", "﻿#{LIVE_KEY}\n") do
      assert_equal "live", Flashpi::Client.new.environment
    end
  end

  def test_validates_its_settings
    [{ base_url: "ftp://x" }, { base_url: "https://" }, { base_url: "not a url" }, { base_url: 7 },
     { timeout: 0 }, { timeout: -1 }, { timeout: Float::NAN }, { timeout: Float::INFINITY },
     { timeout: 2_147_484 }, { timeout: "5" }, { max_retries: -1 }, { max_retries: 1.5 },
     { max_retries: "2" }].each do |settings|
      assert_raises(Flashpi::Error, settings.inspect) { Flashpi::Client.new(api_key: TEST_KEY, **settings) }
    end
  end

  def test_accepts_the_longest_timeout_and_nil_as_the_defaults
    Flashpi::Client.new(api_key: TEST_KEY, timeout: 2_147_483.647, max_retries: 0)
    client = Flashpi::Client.new(api_key: TEST_KEY, base_url: nil, timeout: nil, max_retries: nil, language: nil,
                                 default_headers: nil)
    assert_equal Flashpi::DEFAULT_BASE_URL, client.base_url
  end

  def test_never_shows_the_key
    client = Flashpi::Client.new(api_key: TEST_KEY)
    shown = [client.inspect, client.to_s, PP.pp(client, +"")]
    shown += client.instance_variables.map { |name| client.instance_variable_get(name).inspect }
    shown.each { |text| refute_includes text, TEST_KEY }
    assert_equal "#<Flashpi::Client environment=\"test\" base_url=\"https://api.flashpi.com.ec\">", client.inspect
  end

  def test_cannot_be_serialized_with_its_key
    assert_raises(TypeError) { Marshal.dump(Flashpi::Client.new(api_key: TEST_KEY)) }
  end

  def test_sends_the_key_json_headers_and_the_sdk_version
    api = fake_api(json_response(document_body))
    api.client.invoices.create({ issuerId: ID, total: "1.15" })
    attempt = api.sent.first
    assert_equal :post, attempt.http_method
    assert_equal "https://api.flashpi.com.ec/v1/invoices", attempt.url
    assert_equal "/v1/invoices", attempt.target
    headers = attempt.headers
    assert_equal "Bearer #{TEST_KEY}", headers["authorization"]
    assert_equal "application/json", headers["accept"]
    assert_equal "application/json", headers["content-type"]
    assert_equal "flashpi-ruby/#{Flashpi::VERSION}", headers["user-agent"]
    assert_equal({ issuerId: ID, total: "1.15" }, sent_json(attempt))
  end

  def test_sends_a_json_body_with_an_idempotency_key_on_post
    api = fake_api(json_response({}))
    api.client.webhook_endpoints.create({ url: "https://example.com/hook" })
    key = api.sent.first.headers["idempotency-key"]
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, key)
    assert_equal '{"url":"https://example.com/hook"}', api.sent.first.content
  end

  def test_sends_no_body_when_there_is_none
    api = fake_api(json_response({}), json_response({}))
    api.client.webhook_endpoints.verify(ID)
    api.client.documents.get(ID)
    api.sent.each do |attempt|
      assert_nil attempt.content
      refute attempt.headers.key?("content-type")
    end
  end

  def test_uses_a_fresh_key_per_call_and_the_callers_key_when_given
    api = fake_api(json_response({}), json_response({}), json_response({}))
    api.client.issuers.create({})
    api.client.issuers.create({})
    api.client.issuers.create({}, idempotency_key: "order-42")
    keys = api.sent.map { |attempt| attempt.headers["idempotency-key"] }
    refute_equal keys[0], keys[1]
    assert_equal "order-42", keys[2]
  end

  def test_never_sends_an_idempotency_key_on_patch_delete_or_get
    api = fake_api(json_response({}), raw(204), json_response({}))
    api.client.issuers.update(ID, { legalName: "X" }, idempotency_key: "ignored")
    api.client.issuers.delete(ID)
    api.client.issuers.get(ID)
    api.sent.each { |attempt| refute attempt.headers.key?("idempotency-key") }
  end

  def test_asks_for_the_client_language_and_lets_a_request_override_it
    api = fake_api(json_response({}), json_response({}), json_response({}), language: "es")
    api.client.status.get
    api.client.status.get(language: "en")
    api.client.status.get(language: :en)
    assert_equal(%w[es en en], api.sent.map { |attempt| attempt.headers["accept-language"] })
  end

  def test_does_not_send_an_empty_language
    api = fake_api(json_response({}), language: "es")
    api.client.status.get(language: "  ")
    assert_equal "es", api.sent.first.headers["accept-language"]
    other = fake_api(json_response({}), language: :"")
    other.client.status.get
    refute other.sent.first.headers.key?("accept-language")
  end

  def test_sends_the_correlation_id_and_custom_headers_but_never_replaces_the_key
    api = fake_api(json_response({}), default_headers: { "X-Team" => "billing", "Authorization" => "Bearer nope" })
    api.client.status.get(correlation_id: "order-1", extra_headers: { "X-Team": "erp", "authorization" => "x" })
    headers = api.sent.first.headers
    assert_equal "order-1", headers["x-correlation-id"]
    assert_equal "erp", headers["x-team"]
    assert_equal "Bearer #{TEST_KEY}", headers["authorization"]
  end

  def test_keeps_a_base_url_path_and_drops_its_trailing_slash
    api = fake_api(json_response({}), base_url: "https://proxy.example.com/flashpi/")
    api.client.status.get
    assert_equal "https://proxy.example.com/flashpi/v1/status", api.sent.first.url
    assert_equal "/flashpi/v1/status", api.sent.first.target
  end

  def test_returns_the_response_and_request_id_with_with_response
    api = fake_api(json_response({ status: "operational" }, 200, { "x-request-id" => "req_abc" }))
    result = api.client.status.with_response.get
    assert_instance_of Flashpi::APIResponse, result
    assert_equal({ status: "operational" }, result.data)
    assert_equal 200, result.status
    assert_equal "req_abc", result.request_id
    assert_equal "application/json", result.headers["content-type"]
  end

  def test_reads_text_and_bytes_answers
    pdf = "%PDF-\xff\x00".b
    api = fake_api(raw(200, "<factura/>", { "flashpi-xml-kind" => "authorized" }), raw(200, pdf),
                   raw(200, "<x/>", { "flashpi-xml-kind" => "weird" }))
    assert_equal({ xml: "<factura/>", kind: "authorized" }, api.client.documents.xml(ID))
    data = api.client.documents.pdf(ID)
    assert_equal pdf, data
    assert_equal Encoding::BINARY, data.encoding
    assert_nil api.client.documents.xml(ID)[:kind]
    assert_equal "application/xml, application/problem+json", api.sent[0].headers["accept"]
    assert_equal "application/pdf, application/problem+json", api.sent[1].headers["accept"]
  end

  def test_returns_nil_for_an_empty_or_no_content_answer
    api = fake_api(raw(204), raw(200, ""))
    assert_nil api.client.issuers.delete(ID)
    assert_nil api.client.status.get
  end

  def test_rejects_empty_path_ids_before_sending_anything
    api = fake_api
    ["", "  ", nil, 7, ".", ".."].each do |id|
      assert_raises(Flashpi::Error) { api.client.documents.get(id) }
    end
    assert_empty api.sent
  end

  def test_encodes_path_ids
    api = fake_api(json_response({}))
    api.client.documents.get("a b/c?d#é~!*'()")
    assert_equal "/v1/documents/a%20b%2Fc%3Fd%23%C3%A9~!*'()", api.sent.first.target
  end

  def test_raises_a_flashpi_error_when_a_success_body_is_not_json
    api = fake_api(raw(200, "<html>"))
    error = assert_raises(Flashpi::Error) { api.client.status.get }
    assert_equal "The API answered 200 with a body that is not JSON", error.message
  end

  def test_refuses_unknown_request_options
    api = fake_api
    error = assert_raises(ArgumentError) { api.client.documents.list(status: "authorized") }
    assert_includes error.message, ":status"
    assert_empty api.sent
  end

  def test_refuses_a_body_that_is_not_json
    api = fake_api
    [{ at: Time.now }, { n: Float::NAN }, { "bad" => "\xff".b }, { 1.5 => "x" }, { a: 1, "a" => 2 },
     { amount: Rational(1, 3) }].each do |body|
      assert_raises(TypeError, ArgumentError) { api.client.invoices.create(body) }
    end
    loop_body = {}
    loop_body[:self] = loop_body
    assert_raises(ArgumentError) { api.client.invoices.create(loop_body) }
    assert_empty api.sent
  end

  def test_sends_symbols_text_in_other_encodings_and_the_same_object_twice
    api = fake_api(json_response(document_body))
    item = { code: "P-1" }
    api.client.invoices.create({ items: [item, item], kind: :vat, name: "Ñandú".encode("ISO-8859-1") })
    assert_equal({ items: [{ code: "P-1" }, { code: "P-1" }], kind: "vat", name: "Ñandú" }, sent_json(api.sent.first))
  end

  def test_closes_its_connections
    client = Flashpi::Client.new(api_key: TEST_KEY)
    assert_nil client.close
  end

  def test_exposes_the_webhook_helpers
    assert_same Flashpi::Webhooks, Flashpi::Client.new(api_key: TEST_KEY).webhooks
  end
end
