# frozen_string_literal: true

# The SDK against the real Flashpi API in test mode (SRI pruebas), port of the Python and Node
# SDKs' live suites:
#
#   bundle exec rake test:live
#
# Needs FLASHPI_TEST_API_KEY (an fp_test_ key with read_write access) and FLASHPI_DEMO_ISSUER_ID
# (the demo issuer's id, on the console's Overview); FLASHPI_BASE_URL may point to another API.
# Without them every test is skipped, and `rake test` leaves this suite out. It issues ONE real
# test invoice on the shared demo issuer, which counts toward its daily quota of 50, so CI only
# runs it while a release is being prepared. It never accepts an fp_live_ key.
#
# The tests run in order and share the invoice.

require_relative "../test_helper"

class LiveTest < Minitest::Test
  i_suck_and_my_tests_are_order_dependent!

  API_KEY = ENV.fetch("FLASHPI_TEST_API_KEY", "")
  ISSUER_ID = ENV.fetch("FLASHPI_DEMO_ISSUER_ID", "")
  BASE_URL = ENV.fetch("FLASHPI_BASE_URL", "").then { |url| url.empty? ? nil : url }
  IDEMPOTENCY_KEY = "sdk-live-ruby-#{Time.now.to_i.to_s(16)}-#{SecureRandom.uuid}".freeze
  # Checks of a slow SRI step, 5 seconds apart: up to 2 minutes.
  POLLS = 24

  @issued = nil
  class << self
    attr_accessor :issued
  end

  # The same test invoice as the docs' quickstart: USD 1.00 + 15 % VAT to the SRI's test RUC.
  def sample_invoice
    {
      issuerId: ISSUER_ID,
      establishment: "001",
      emissionPoint: "001",
      customer: {
        idType: "ruc", id: "1760013210001", name: "PRUEBAS SERVICIO DE RENTAS INTERNAS",
        address: "AMAZONAS AVENUE AND VILLALENGUA, QUITO"
      },
      items: [
        { code: "SDK-LIVE-001", description: "flashpi (Ruby) live test", quantity: "1", unitPrice: "1.00",
          taxes: [{ type: "vat", rate: "15" }] }
      ],
      payments: [{ method: "cash", amount: "1.15" }],
      options: { waitForAuthorization: true, waitTimeoutSeconds: 30, sendEmail: false }
    }
  end

  def setup
    check_settings
    @flashpi = Flashpi::Client.new(api_key: API_KEY, base_url: BASE_URL)
  end

  def teardown
    @flashpi&.close
  end

  def test_0_reads_the_api_status
    assert_equal({ status: "operational" }, @flashpi.status.get)
  end

  def test_1_rejects_an_invalid_invoice_with_field_errors_in_spanish
    body = sample_invoice.merge(items: [])
    error = assert_raises(Flashpi::UnprocessableEntityError) { @flashpi.invoices.create(body, language: "es", max_retries: 0) }
    assert_equal "validation_failed", error.code
    refute_empty error.errors
    assert_match(/\A[0-9a-f-]{36}\z/, error.request_id)
    assert_equal "es", error.headers["content-language"]
  end

  def test_2_issues_a_test_invoice_and_waits_for_the_sri
    result = @flashpi.invoices.with_response.create(sample_invoice, idempotency_key: IDEMPOTENCY_KEY,
                                                                    correlation_id: "flashpi-ruby-live")
    assert_includes [200, 202], result.status
    refute_nil result.request_id
    assert_equal %w[invoice test], [result.data[:type], result.data[:environment]]
    document = result.data
    # The SRI's test environment can be slow: follow the document for up to 2 minutes.
    POLLS.times do
      break unless %w[processing pending_sri].include?(document[:status])

      sleep 5
      document = @flashpi.documents.get(document[:id])
    end
    assert_equal "authorized", document[:status]
    assert_match(/\A\d{49}\z/, document[:accessKey])
    self.class.issued = document
  end

  def test_3_replays_the_same_idempotency_key_instead_of_issuing_again
    result = @flashpi.invoices.with_response.create(sample_invoice, idempotency_key: IDEMPOTENCY_KEY)
    assert_equal issued_invoice[:id], result.data[:id]
    assert_equal "true", result.headers["idempotent-replayed"]
  end

  def test_4_finds_the_document_by_its_access_key
    page = @flashpi.documents.list({ accessKey: issued_invoice[:accessKey], limit: 5 })
    assert_equal([issued_invoice[:id]], page.data.map { |document| document[:id] })
  end

  def test_5_downloads_the_authorized_xml
    xml = @flashpi.documents.xml(issued_invoice[:id])
    assert_equal "authorized", xml[:kind]
    assert_includes xml[:xml], issued_invoice[:accessKey]
  end

  def test_6_downloads_the_ride_once_it_is_generated
    pdf = nil
    POLLS.times do
      pdf = @flashpi.documents.pdf(issued_invoice[:id])
      break
    rescue Flashpi::ConflictError => e
      raise unless e.code == "ride_not_available"

      sleep 5
    end
    assert pdf&.start_with?("%PDF-".b)
  end

  def test_7_lists_the_events_of_the_document
    types = []
    12.times do |poll|
      break if types.include?("invoice.authorized")

      sleep 5 if poll.positive?
      types = @flashpi.events.list({ documentId: issued_invoice[:id] }).map do |event|
        assert_equal issued_invoice[:id], event[:data][:id]
        event[:type]
      end
    end
    assert_includes types, "invoice.authorized"
  end

  def test_8_answers_404_for_a_document_that_does_not_exist
    assert_raises(Flashpi::NotFoundError) { @flashpi.documents.get("01a00000-0000-7000-8000-000000000000", max_retries: 0) }
  end

  private

  def check_settings
    skip "needs FLASHPI_TEST_API_KEY and FLASHPI_DEMO_ISSUER_ID" if API_KEY.empty? || ISSUER_ID.empty?
    return if API_KEY.start_with?("fp_test_")

    raise "FLASHPI_TEST_API_KEY must be an fp_test_ key: this suite never runs live"
  end

  def issued_invoice
    self.class.issued || flunk("The test invoice was not issued: see test_2_issues_a_test_invoice")
  end
end
