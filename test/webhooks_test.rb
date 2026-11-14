# frozen_string_literal: true

require_relative "test_helper"

class WebhooksTest < Minitest::Test
  include Support

  Vector = Struct.new(:secret, :id, :timestamp, :body, :signature, keyword_init: true)

  # The example of the Standard Webhooks specification (24-byte key).
  STANDARD = Vector.new(
    secret: "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", id: "msg_p5jXN8AQM9LWM0D4loKWxJek",
    timestamp: "1614265330", body: '{"test": 2432232314}',
    signature: "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="
  )

  # The example of Flashpi's webhook docs (32-byte key), the same the API's tests sign.
  FLASHPI = Vector.new(
    secret: "whsec_Zmxhc2hwaS1kb2NzLWV4YW1wbGUtc2VjcmV0LTMyLWI=", id: "019a1b2c-3d4e-7f60-8a1b-2c3d4e5f6a7b",
    timestamp: "1792152000",
    body: '{"id":"019a1b2c-3d4e-7f60-8a1b-2c3d4e5f6a7b","type":"invoice.authorized",' \
          '"environment":"test","createdAt":"2026-10-16T17:20:00.000Z"}',
    signature: "v1,HbWOpDPWCo3wtq41t9GVHUpg69M1zgvveoDJmSWkA8U="
  )

  DECOY = "v1,Ceo5qEr07ixe2NLpvHk3FH9bwy/WavXrAFQ/9tdO6mc="

  def headers_of(vector, signature = nil)
    { "webhook-id" => vector.id, "webhook-timestamp" => vector.timestamp,
      "webhook-signature" => signature || vector.signature }
  end

  def at(vector, offset = 0)
    vector.timestamp.to_i + offset
  end

  def reason
    yield
    :verified
  rescue Flashpi::WebhookVerificationError => e
    e.reason
  end

  def verify(body, headers, secret = FLASHPI.secret, now: at(FLASHPI), **)
    Flashpi::Webhooks.verify_signature(body, headers, secret, now:, **)
  end

  def sign(secret, vector, body)
    key = secret.delete_prefix("whsec_").unpack1("m")
    "v1,#{[OpenSSL::HMAC.digest("SHA256", key, "#{vector.id}.#{vector.timestamp}.#{body}")].pack("m0")}"
  end

  def test_accepts_the_standard_webhooks_example
    assert_equal(:verified, reason { verify(STANDARD.body, headers_of(STANDARD), STANDARD.secret, now: at(STANDARD)) })
  end

  def test_accepts_the_example_of_flashpis_docs
    assert_nil verify(FLASHPI.body, headers_of(FLASHPI))
  end

  def test_signs_the_raw_bytes_of_a_utf8_body_in_any_encoding_label
    body = '{"id":"019a1b2c-3d4e-7f60-8a1b-2c3d4e5f6a7b","type":"invoice.authorized",' \
           '"environment":"test","createdAt":"2026-10-16T17:20:00.000Z",' \
           '"data":{"counterparty":{"name":"Panadería Ñandú €"}}}'
    headers = headers_of(FLASHPI, "v1,fdAGYFcvd+G8WvVy6jtQtuduKm8mENxuA/zTqcWYSJY=")
    assert_equal 191, body.bytesize
    [body, body.b, body.dup.force_encoding("ISO-8859-1")].each { |payload| verify(payload, headers) }
  end

  def test_accepts_a_body_of_any_bytes
    headers = headers_of(STANDARD, "v1,sEcZ042G8Crqgxbybb3y0eDxQR3TcfYsk11I1XULhSI=")
    verify((0..255).to_a.pack("C*"), headers, STANDARD.secret, now: at(STANDARD))
  end

  def test_accepts_either_secret_during_a_rotation
    rotation = "#{FLASHPI.signature} v1,dZdgetSIp5ZOSjhz50Gcz1N1hb/WBvK3IdncOP52NrQ="
    [FLASHPI.secret, STANDARD.secret].each { |secret| verify(FLASHPI.body, headers_of(FLASHPI, rotation), secret) }
  end

  def test_skips_decoys_malformed_entries_and_other_versions
    signature = [DECOY, "v2,#{FLASHPI.signature[3..]}", "v1", "v1,not-base64!", "", FLASHPI.signature].join(" ")
    verify(FLASHPI.body, headers_of(FLASHPI, signature))
  end

  def test_accepts_the_secret_without_its_prefix_and_with_spaces_around_it
    verify(FLASHPI.body, headers_of(FLASHPI), " #{FLASHPI.secret.delete_prefix("whsec_")}\n")
  end

  def test_rejects_bad_signatures
    [[FLASHPI.body.sub("test", "live"), FLASHPI.signature], [FLASHPI.body, "v2,#{FLASHPI.signature[3..]}"],
     [FLASHPI.body, FLASHPI.signature[0..-5]], [FLASHPI.body, "v1,"], [FLASHPI.body, "v1,dawfeoifkpqwoekfpqoekf"],
     [FLASHPI.body, "#{FLASHPI.signature}\tv1,x"],
     [FLASHPI.body, "v1,#{FLASHPI.signature[3..]}A"]].each do |body, signature|
      assert_equal(:no_matching_signature, reason { verify(body, headers_of(FLASHPI, signature)) }, signature)
    end
  end

  def test_accepts_a_signature_without_its_padding_like_atob
    verify(FLASHPI.body, headers_of(FLASHPI, FLASHPI.signature.delete_suffix("=")))
  end

  def test_rejects_a_body_signed_with_another_secret
    assert_equal(:no_matching_signature, reason { verify(FLASHPI.body, headers_of(FLASHPI), STANDARD.secret) })
  end

  def test_accepts_timestamps_up_to_5_minutes_away_and_rejects_others
    assert_equal 300, Flashpi::Webhooks::TOLERANCE_SECONDS
    results = [300, -300, 301, -301].map do |offset|
      reason do
        verify(FLASHPI.body, headers_of(FLASHPI), now: at(FLASHPI, offset))
      end
    end
    assert_equal %i[verified verified timestamp_out_of_range timestamp_out_of_range], results
  end

  def test_takes_another_tolerance_and_a_time_as_now
    error = assert_raises(Flashpi::WebhookVerificationError) do
      verify(FLASHPI.body, headers_of(FLASHPI), tolerance: 10, now: Time.at(at(FLASHPI, 11)))
    end
    assert_equal :timestamp_out_of_range, error.reason
    assert_includes error.message, "more than 10 seconds"
    verify(FLASHPI.body, headers_of(FLASHPI), tolerance: 10.5, now: Time.at(at(FLASHPI, 10)))
    error = assert_raises(Flashpi::WebhookVerificationError) do
      verify(FLASHPI.body, headers_of(FLASHPI), tolerance: 2.5, now: at(FLASHPI, 3))
    end
    assert_includes error.message, "more than 2.5 seconds"
  end

  def test_checks_the_timestamp_against_the_current_clock_by_default
    assert_equal(:timestamp_out_of_range, reason do
      Flashpi::Webhooks.verify_signature(FLASHPI.body, headers_of(FLASHPI), FLASHPI.secret)
    end)
  end

  def test_rejects_a_request_without_a_header_or_with_an_empty_one
    %w[webhook-id webhook-timestamp webhook-signature].each do |name|
      headers = headers_of(FLASHPI).except(name)
      assert_equal(:missing_headers, reason { verify(FLASHPI.body, headers) })
      assert_equal(:missing_headers, reason { verify(FLASHPI.body, headers_of(FLASHPI).merge(name => "")) })
    end
  end

  def test_rejects_an_invalid_timestamp
    ["abc", "-1", "1792152000.5", "1234567890123", "١٧٩", "1792152000\n", " 1792152000"].each do |timestamp|
      headers = headers_of(FLASHPI).merge("webhook-timestamp" => timestamp)
      assert_equal(:invalid_timestamp, reason { verify(FLASHPI.body, headers) }, timestamp.inspect)
    end
  end

  def test_refuses_an_invalid_secret
    ["", "whsec_", "   ", "whsec_not base64!", "whsec_a", "whsec_ab=", "whsec_#{"QUFB" * 30}", nil, 42].each do |secret|
      assert_equal(:invalid_secret, reason { verify(FLASHPI.body, headers_of(FLASHPI), secret) }, secret.inspect)
    end
  end

  def test_refuses_a_body_that_was_already_parsed
    [JSON.parse(FLASHPI.body), nil, 42].each do |payload|
      assert_equal(:invalid_payload, reason { verify(payload, headers_of(FLASHPI)) })
    end
  end

  def test_rejects_a_webhook_id_with_bytes_that_are_not_utf8
    garbled = headers_of(FLASHPI).merge("webhook-id" => "msg_\xff")
    assert_equal(:no_matching_signature, reason { verify(FLASHPI.body, garbled) })
    signature = sign(FLASHPI.secret, Vector.new(id: "msg_\xff".b, timestamp: FLASHPI.timestamp), FLASHPI.body.b)
    verify(FLASHPI.body, garbled.merge("webhook-signature" => signature))
  end

  def test_reads_headers_in_any_letter_case_rack_env_and_repeated_values
    variants = [
      { "Webhook-Id" => FLASHPI.id, "WEBHOOK-TIMESTAMP" => FLASHPI.timestamp,
        "webhook-signature" => FLASHPI.signature },
      { "webhook-id" => [FLASHPI.id, "ignored"], "webhook-timestamp" => [FLASHPI.timestamp],
        "webhook-signature" => [DECOY, FLASHPI.signature], "other" => nil, 7 => "x" },
      { "HTTP_WEBHOOK_ID" => FLASHPI.id, "HTTP_WEBHOOK_TIMESTAMP" => FLASHPI.timestamp,
        "HTTP_WEBHOOK_SIGNATURE" => FLASHPI.signature, "rack.input" => StringIO.new },
      { "webhook-id": FLASHPI.id, "webhook-timestamp": FLASHPI.timestamp, "webhook-signature": FLASHPI.signature },
      [["webhook-id", FLASHPI.id], ["webhook-timestamp", FLASHPI.timestamp], ["webhook-signature", DECOY],
       ["webhook-signature", FLASHPI.signature]]
    ]
    variants.each { |headers| verify(FLASHPI.body, headers) }
    assert_raises(TypeError) { verify(FLASHPI.body, "webhook-id: x") }
  end

  def test_ends_in_a_verification_error_whatever_the_encoding_of_the_headers_or_the_secret
    utf16 = ->(text) { text.encode("UTF-16LE") }
    cases = [
      [headers_of(FLASHPI).merge("webhook-timestamp" => "1792152000\xff"), FLASHPI.secret, :invalid_timestamp],
      [headers_of(FLASHPI, "v1,\xff"), FLASHPI.secret, :no_matching_signature],
      [headers_of(FLASHPI, "#{FLASHPI.signature} \xff"), FLASHPI.secret, :verified],
      [headers_of(FLASHPI).merge("x-\xff" => "1"), FLASHPI.secret, :verified],
      [headers_of(FLASHPI).merge("webhook-timestamp" => utf16.call(FLASHPI.timestamp)), FLASHPI.secret,
       :invalid_timestamp],
      [headers_of(FLASHPI, utf16.call(FLASHPI.signature)), FLASHPI.secret, :no_matching_signature],
      [headers_of(FLASHPI).merge("webhook-signature" => ["v1,\xff".b, "v1,é", FLASHPI.signature]), FLASHPI.secret,
       :verified],
      [headers_of(FLASHPI), "#{FLASHPI.secret}\xff", :invalid_secret],
      [headers_of(FLASHPI), utf16.call(FLASHPI.secret), :invalid_secret]
    ]
    key = FLASHPI.secret.delete_prefix("whsec_").unpack1("m")
    cases.each do |headers, secret, expected|
      assert_equal(expected, reason { verify(FLASHPI.body, headers, secret) }, headers.inspect)
      locals_at_raise { verify(FLASHPI.body, headers, secret) }.each do |locals|
        refute_includes locals, FLASHPI.secret.delete_prefix("whsec_")
        refute_includes locals, key.inspect[1..-2]
      end
    end
  end

  def test_signs_a_non_ascii_id_and_body_in_utf8_or_binary
    vector = Vector.new(id: "msg_ñandú", timestamp: FLASHPI.timestamp)
    body = '{"name":"Panadería Ñandú €"}'
    signature = sign(FLASHPI.secret, vector, body)
    headers = { "webhook-id" => vector.id, "webhook-timestamp" => vector.timestamp, "webhook-signature" => signature }
    verify(body, headers)
    verify(body.b, headers.transform_values(&:b))
  end

  def test_unwrap_returns_the_verified_event_with_symbol_keys
    event = Flashpi::Webhooks.unwrap(FLASHPI.body, headers_of(FLASHPI), FLASHPI.secret, now: at(FLASHPI))
    assert_equal JSON.parse(FLASHPI.body, symbolize_names: true), event
    assert_equal "invoice.authorized", event[:type]
    refute event.key?(:data)
  end

  def test_unwrap_raises_before_parsing_when_the_signature_is_wrong
    assert_equal(:no_matching_signature, reason do
      Flashpi::Webhooks.unwrap("not json", headers_of(FLASHPI), FLASHPI.secret, now: at(FLASHPI))
    end)
  end

  def test_unwrap_raises_invalid_payload_for_a_signed_body_that_is_not_a_json_object
    ["not json", "[1, 2]", '"text"', "#{"[" * 600}#{"]" * 600}"].each do |body|
      headers = headers_of(STANDARD, sign(STANDARD.secret, STANDARD, body))
      assert_equal(:invalid_payload, reason do
        Flashpi::Webhooks.unwrap(body, headers, STANDARD.secret, now: at(STANDARD))
      end)
    end
  end

  def test_is_available_on_the_client
    client = Flashpi::Client.new(api_key: TEST_KEY)
    assert_equal FLASHPI.id,
                 client.webhooks.unwrap(FLASHPI.body, headers_of(FLASHPI), FLASHPI.secret, now: at(FLASHPI))[:id]
    assert_nil client.webhooks.verify_signature(FLASHPI.body, headers_of(FLASHPI), FLASHPI.secret, now: at(FLASHPI))
  end

  def test_refuses_bad_options_instead_of_skipping_the_time_check
    [[{ tolerance: Float::NAN }, ArgumentError], [{ tolerance: -1 }, ArgumentError],
     [{ tolerance: Float::INFINITY }, ArgumentError], [{ tolerance: "300" }, TypeError],
     [{ tolerance: true }, TypeError],
     [{ now: Float::NAN }, ArgumentError], [{ now: Float::INFINITY }, ArgumentError], [{ now: 10**400 }, ArgumentError],
     [{ now: "2026-10-16" }, TypeError], [{ now: false }, TypeError]].each do |options, error_class|
      assert_raises(error_class, options.inspect) { verify(FLASHPI.body, headers_of(FLASHPI), **options) }
    end
  end

  def test_keeps_the_secret_its_key_and_the_expected_signature_out_of_the_frames_that_raise
    key = FLASHPI.secret.delete_prefix("whsec_").unpack1("m")
    expected = FLASHPI.signature.delete_prefix("v1,").unpack1("m")
    cases = [
      [headers_of(FLASHPI, DECOY), FLASHPI.body], [{ "webhook-id" => FLASHPI.id }, FLASHPI.body],
      [headers_of(FLASHPI).merge("webhook-timestamp" => "x"), FLASHPI.body],
      [headers_of(FLASHPI).merge("webhook-timestamp" => "1"), FLASHPI.body], [headers_of(FLASHPI), { parsed: true }]
    ]
    cases.each do |headers, payload|
      locals_at_raise { verify(payload, headers) }.each do |locals|
        refute_includes locals, key.inspect[1..-2]
        refute_includes locals, expected.inspect[1..-2]
        refute_includes locals, FLASHPI.secret
      end
    end
    ["whsec_a", "whsec_#{"QUFB" * 30}"].each do |secret|
      locals_at_raise { verify(FLASHPI.body, headers_of(FLASHPI), secret) }.each do |locals|
        refute_includes locals, "AAA" * 10
      end
    end
  end
end
