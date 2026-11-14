# frozen_string_literal: true

require_relative "test_helper"

# The API key, a .p12 and its password never show in inspect, messages, serialized objects or the
# local variables of the methods that raise.
class SecretsTest < Minitest::Test
  include Support

  P12 = "P12-BYTES-\x30\x82".b
  PASSWORD = "pass-word-123"

  def test_a_secret_hides_its_value
    secret = Flashpi::Internal::Secret.new(TEST_KEY)
    [secret.inspect, secret.to_s, PP.pp(secret, +""), secret.instance_variables.inspect].each do |shown|
      refute_includes shown, TEST_KEY
    end
    assert_equal TEST_KEY, secret.reveal
    assert_raises(TypeError) { Marshal.dump(secret) }
    assert_predicate secret, :frozen?
  end

  def test_the_config_and_the_attempts_hide_the_key
    api = fake_api(json_response({}))
    api.client.status.get
    attempt = api.sent.first
    engine = api.client.instance_variable_get(:@engine)
    [attempt.inspect, engine.config.inspect, engine.inspect, PP.pp(attempt, +""), PP.pp(engine, +"")].each do |shown|
      refute_includes shown, TEST_KEY
    end
  end

  def test_a_multipart_body_shows_only_its_part_names
    form = Flashpi::Internal::Multipart.certificate({ file: P12, password: PASSWORD })
    assert_equal '#<Flashpi::Internal::Multipart fields=["password"] files=["file"]>', form.inspect
    refute_includes PP.pp(form, +""), PASSWORD
    assert_raises(TypeError) { Marshal.dump(form) }
    spec = Flashpi::Internal::RequestSpec.new(http_method: :post, path: "/v1/x", multipart: form)
    refute_includes spec.inspect, PASSWORD
  end

  def test_keeps_the_key_out_of_the_locals_of_a_refused_setting_or_key
    [{ api_key: "fp_test_bad key" }, { api_key: TEST_KEY, timeout: 0 }, { api_key: TEST_KEY, base_url: "ftp://x" },
     { api_key: TEST_KEY, default_headers: { "X" => 1 } }, { api_key: TEST_KEY, max_retries: -1 }].each do |settings|
      locals_at_raise { Flashpi::Client.new(**settings) }.each do |locals|
        refute_includes locals, "fp_test_bad key"
        refute_includes locals, TEST_KEY
      end
    end
  end

  def test_keeps_the_key_out_of_the_locals_of_a_request_error
    api = fake_api(problem(500, "internal_error"), network_error, problem(404, "not_found"), max_retries: 0)
    [-> { api.client.status.get }, -> { api.client.status.get }, -> { api.client.issuers.delete("x") },
     -> { api.client.status.get(timeout: -1) }, -> { api.client.status.get(nope: 1) }].each do |call|
      locals_at_raise(&call).each { |locals| refute_includes locals, TEST_KEY }
    end
  end

  def test_keeps_the_p12_and_its_password_out_of_the_locals_of_an_upload_error
    big = "x" * (Flashpi::Internal::Multipart::MAX_CERTIFICATE_BYTES + 1)
    uploads = [{ file: "", password: PASSWORD }, { file: big, password: PASSWORD }, { file: P12, password: 1 },
               { file: P12, password: PASSWORD, filename: 1 }, { file: 1, password: PASSWORD }, P12,
               { file: StringIO.new(big), password: PASSWORD }]
    api = fake_api
    uploads.each do |upload|
      locals_at_raise { api.client.issuer_onboardings.create(upload) }.each do |locals|
        refute_includes locals, PASSWORD
        refute_includes locals, "P12-BYTES"
        refute_includes locals, "xxxxxxxxxx"
      end
    end
    assert_empty api.sent
  end

  def test_keeps_the_p12_and_its_password_out_of_the_locals_once_the_api_answered
    upload = { file: P12, password: PASSWORD }
    [[problem(422, "invalid_certificate_password")], [network_error, network_error, network_error],
     [raw(200, "<html>")], [problem(500, "internal_error"), problem(422, "validation_failed")]].each do |replies|
      api = fake_api(*replies, max_retries: 2)
      captured = locals_at_raise { api.client.issuer_onboardings.create(upload) }
      refute_empty captured
      captured.each do |locals|
        refute_includes locals, PASSWORD
        refute_includes locals, "P12-BYTES"
      end
      refute_empty api.sent
    end
  end

  def test_an_attempt_and_its_call_hide_the_body
    api = fake_api(json_response({}))
    api.client.issuer_onboardings.create({ file: P12, password: PASSWORD })
    attempt = api.sent.first
    shown = [attempt.inspect, PP.pp(attempt, +"")] + attempt.instance_variables.map do |name|
      attempt.instance_variable_get(name).inspect
    end
    shown.each { |text| refute_includes text, PASSWORD }
    assert_includes attempt.content, PASSWORD
  end

  def test_messages_never_show_the_key
    api = fake_api(problem(401, "invalid_api_key"))
    error = assert_raises(Flashpi::AuthenticationError) { api.client.status.get }
    refute_includes error.message, TEST_KEY
    refute_includes error.inspect, TEST_KEY
    refute_includes error.full_message, TEST_KEY
  end
end
