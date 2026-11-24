# frozen_string_literal: true

require_relative "test_helper"

class ResourcesTest < Minitest::Test
  include Support

  P12 = "\x30\x82\x01\x02".b

  def test_sends_an_empty_object_to_complete_an_onboarding_without_a_body
    api = fake_api(json_response({}), json_response({}))
    api.client.issuer_onboardings.complete(ID)
    api.client.issuer_onboardings.complete(ID, { legalName: "X" })
    assert_equal ["{}", '{"legalName":"X"}'], api.sent.map(&:content)
  end

  def test_rotates_a_secret_without_a_body_unless_one_is_given
    api = fake_api(json_response({}), json_response({}))
    api.client.webhook_endpoints.rotate_secret(ID)
    api.client.webhook_endpoints.rotate_secret(ID, { previousSecretExpiresInHours: 0 })
    assert_nil api.sent[0].content
    assert_equal '{"previousSecretExpiresInHours":0}', api.sent[1].content
  end

  def test_always_sends_an_empty_object_to_email_a_document
    api = fake_api(json_response(document_body))
    api.client.documents.send_email(ID)
    assert_equal "{}", api.sent.first.content
  end

  # The API gives a last payment that leaves out its amount the rest of the total: the types allow
  # it, and the body goes out without the key.
  def test_sends_a_last_payment_without_its_amount
    api = fake_api(json_response(document_body), json_response(document_body))
    payments = [{ method: "credit_card", amount: "10.00" }, { method: "cash" }]
    api.client.invoices.create({ issuerId: ID, payments: })
    api.client.withholdings.create({ issuerId: ID, supportingDocuments: [{ payments: [{ method: "cash" }] }] })
    assert_equal %({"issuerId":"#{ID}","payments":[{"method":"credit_card","amount":"10.00"},{"method":"cash"}]}),
                 api.sent[0].content
    assert_equal %({"issuerId":"#{ID}","supportingDocuments":[{"payments":[{"method":"cash"}]}]}), api.sent[1].content
    assert typed?(payments, "::Array[::Flashpi::Types::document_payment]")
    assert typed?([{ method: "cash" }], "::Array[::Flashpi::Types::withholding_payment]")
    refute typed?([{ amount: "10.00" }], "::Array[::Flashpi::Types::document_payment]")
  end

  def test_sends_the_same_multipart_body_on_every_attempt
    api = fake_api(network_error, json_response({ id: "onb" }))
    file = StringIO.new(P12)
    assert_equal "onb", api.client.issuer_onboardings.create({ "file" => file, "password" => "x" })[:id]
    assert_equal 2, api.sent.size
    assert_equal api.sent[0].content, api.sent[1].content
    assert_equal api.sent[0].headers["content-type"], api.sent[1].headers["content-type"]
    assert_includes api.sent[0].content, "filename=\"certificate.p12\""
  end

  def test_reads_a_certificate_from_bytes_or_an_io_in_pieces
    form = Flashpi::Internal::Multipart.certificate({ file: P12, password: "x", filename: "firma.p12" })
    assert_includes form.content, "filename=\"firma.p12\"\r\nContent-Type: application/x-pkcs12\r\n\r\n#{P12}\r\n".b
    reader = Class.new do
      def initialize = @chunks = ["\x30".b, "\x82".b, ""]
      def read(_length) = @chunks.shift
    end
    assert_includes Flashpi::Internal::Multipart.certificate({ file: reader.new, password: "x" }).content,
                    "\x30\x82\r\n".b
    exact = "a" * Flashpi::Internal::Multipart::MAX_CERTIFICATE_BYTES
    Flashpi::Internal::Multipart.certificate({ file: StringIO.new(exact), password: "x" })
  end

  def test_refuses_a_bad_certificate_upload_before_sending
    api = fake_api
    big = StringIO.new("a" * (Flashpi::Internal::Multipart::MAX_CERTIFICATE_BYTES + 10))
    [[{ file: "", password: "x" }, Flashpi::Error], [{ file: big, password: "x" }, Flashpi::Error],
     [{ file: P12, password: nil }, Flashpi::Error], [{ file: P12 }, Flashpi::Error],
     [{ file: P12, password: "x", filename: :f }, TypeError], [{ file: 42, password: "x" }, TypeError],
     [{ file: Object.new.tap { |io| io.define_singleton_method(:read) { |_| 42 } }, password: "x" }, TypeError],
     [P12, TypeError]].each do |upload, error|
      assert_raises(error, upload.inspect) { api.client.issuers.certificates.upload(ID, upload) }
    end
    assert_empty api.sent
    message = assert_raises(Flashpi::Error) do
      api.client.issuer_onboardings.create({ file: big.tap(&:rewind), password: "x" })
    end.message
    assert_equal "The certificate file has more than 1048576 bytes, the most the API accepts", message
    assert_operator big.pos, :<=, Flashpi::Internal::Multipart::MAX_CERTIFICATE_BYTES + 1
  end

  def test_sends_the_password_and_the_file_name_as_utf8
    form = Flashpi::Internal::Multipart.certificate({ file: P12, password: "contraseña".encode("ISO-8859-1"),
                                                      filename: "firma ñ.p12".encode("ISO-8859-1") })
    assert_includes form.content, "\r\n\r\ncontraseña\r\n".b
    assert_includes form.content, "filename=\"firma ñ.p12\"".b
    assert_raises(ArgumentError) { Flashpi::Internal::Multipart.certificate({ file: P12, password: "ab\xff" }) }
    assert_raises(ArgumentError) { Flashpi::Internal::Multipart.certificate({ file: P12, password: "x", filename: "\xff" }) }
  end

  def test_refuses_a_with_response_call_that_sent_no_request
    view = Flashpi::Resources::Status::WithResponse.new(Object.new.tap do |fake|
      fake.define_singleton_method(:get) do |**|
        nil
      end
    end)
    error = assert_raises(Flashpi::Error) { view.get }
    assert_equal "The call sent no request, so there is no response to return", error.message
  end

  def test_with_response_keeps_the_same_view_and_shows_its_class
    client = Flashpi::Client.new(api_key: TEST_KEY)
    assert_same client.documents.with_response, client.documents.with_response
    assert_equal "#<Flashpi::Resources::Documents::WithResponse>", client.documents.with_response.inspect
    assert_equal "#<Flashpi::Resources::Invoices>", client.invoices.inspect
  end

  def test_with_response_is_fiber_local
    api = fake_api(json_response({ a: 1 }), json_response({ b: 2 }))
    result = api.client.status.with_response.get
    assert_equal({ a: 1 }, result.data)
    assert_equal({ b: 2 }, api.client.status.get)
    assert_nil Thread.current[Flashpi::Internal::ResponseView::SLOT]
  end
end
