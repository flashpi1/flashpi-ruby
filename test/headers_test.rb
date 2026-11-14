# frozen_string_literal: true

require_relative "test_helper"

# Every value that becomes a header is checked before anything is sent, so a bad one is never
# retried as a network failure.
class HeadersTest < Minitest::Test
  include Support

  def test_trims_the_spaces_around_the_values_of_every_option
    api = fake_api(json_response({}))
    api.client.issuers.create({}, idempotency_key: " k-1\t", correlation_id: "\r\nc-1 ", language: " es ",
                                  extra_headers: { "X-A" => "  a  " })
    headers = api.sent.first.headers
    assert_equal %w[k-1 c-1 es a], headers.values_at("idempotency-key", "x-correlation-id", "accept-language", "x-a")
  end

  def test_keeps_tabs_spaces_and_text_outside_ascii_inside_a_value
    api = fake_api(json_response({}))
    api.client.status.get(extra_headers: { "X-A" => "a \t b ñ €" })
    assert_equal "a \t b ñ €", api.sent.first.headers["x-a"]
  end

  def test_takes_the_last_spelling_of_a_repeated_idempotency_key_header
    api = fake_api(json_response({}))
    api.client.issuers.create({}, extra_headers: { "Idempotency-Key" => "first", "idempotency-key" => " second " })
    assert_equal "second", api.sent.first.headers["idempotency-key"]
  end

  def test_puts_the_trimmed_idempotency_key_on_errors
    api = fake_api(problem(422, "validation_failed"))
    error = assert_raises(Flashpi::UnprocessableEntityError) { api.client.issuers.create({}, idempotency_key: " k-2 ") }
    assert_equal "k-2", error.idempotency_key
  end

  def test_refuses_a_control_character_or_invalid_text_in_any_value_without_showing_it
    api = fake_api
    ["a\nb", "a\rb", "a\u0000b", "a\u007fb", "a\u0001b", "secret\xff"].each do |value|
      [{ idempotency_key: value }, { correlation_id: value }, { language: value },
       { extra_headers: { "X-A" => value } }].each do |options|
        error = assert_raises(ArgumentError) { api.client.issuers.create({}, **options) }
        refute_includes error.message, value
      end
    end
    assert_empty api.sent
  end

  def test_refuses_a_bad_header_name
    api = fake_api
    ["X A", "X:A", "", "Ñ", "X\nA"].each do |name|
      assert_raises(ArgumentError) { api.client.status.get(extra_headers: { name => "x" }) }
    end
    assert_raises(TypeError) { api.client.status.get(extra_headers: { 1 => "x" }) }
  end

  def test_refuses_a_header_that_frames_the_body
    api = fake_api
    %w[Content-Length transfer-encoding].each do |name|
      assert_raises(ArgumentError) { api.client.status.get(extra_headers: { name => "1" }) }
      assert_raises(ArgumentError) { Flashpi::Client.new(api_key: TEST_KEY, default_headers: { name => "1" }) }
    end
  end

  def test_refuses_an_option_that_is_not_text
    api = fake_api
    [{ idempotency_key: 1 }, { correlation_id: :x }, { language: 1 }, { extra_headers: { "X-A" => 1 } },
     { extra_headers: [%w[X-A 1]] }].each do |options|
      assert_raises(TypeError) { api.client.issuers.create({}, **options) }
    end
  end

  def test_checks_the_client_settings
    assert_raises(ArgumentError) { Flashpi::Client.new(api_key: TEST_KEY, default_headers: { "X-A" => "a\nb" }) }
    assert_raises(ArgumentError) { Flashpi::Client.new(api_key: TEST_KEY, language: "e\ns") }
    assert_raises(TypeError) { Flashpi::Client.new(api_key: TEST_KEY, language: 1) }
    assert_raises(TypeError) { Flashpi::Client.new(api_key: TEST_KEY, default_headers: "X-A: 1") }
    error = assert_raises(Flashpi::Error) { Flashpi::Client.new(api_key: TEST_KEY, default_headers: { "Idempotency-Key" => " k " }) }
    assert_includes error.message, "Idempotency-Key"
    assert_raises(Flashpi::Error) { Flashpi::Client.new(api_key: TEST_KEY, default_headers: { "IDEMPOTENCY-KEY" => "k" }) }
  end

  # Against a local server: net/http checks the headers once it is connected, and reaching the
  # real API within the deadline depends on the network.
  def test_a_request_net_http_refuses_is_a_flashpi_error_without_its_reason
    server = LocalServer.new { |_request, socket| LocalServer.respond(socket, 200) }
    transport = Flashpi::Internal::Transport.new(server.url)
    url = "#{server.url}/v1/status"
    headers = { "authorization" => "Bearer #{TEST_KEY}\r\nx" }
    attempt = Flashpi::Internal::Attempt.new(http_method: :get, url:, target: "/v1/status", headers:,
                                             content: nil, timeout: 10.0, response_type: :json)
    error = assert_raises(Flashpi::Error) { transport.perform(attempt) }
    assert_equal "GET #{url} was not sent: net/http refused it as invalid HTTP", error.message
    assert_nil error.cause
    refute_kind_of Flashpi::APIConnectionError, error
    assert_empty server.received
  ensure
    server&.close
  end
end
