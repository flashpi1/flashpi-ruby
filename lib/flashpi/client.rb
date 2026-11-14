# frozen_string_literal: true

module Flashpi
  # The address of the Flashpi API.
  DEFAULT_BASE_URL = "https://api.flashpi.com.ec"
  # Seconds each attempt of a request may take, from sending it to reading the whole answer (the
  # Node SDK's 60 000 ms).
  DEFAULT_TIMEOUT = 60.0
  # Retries after network errors, timeouts, 429 and 5xx.
  DEFAULT_MAX_RETRIES = 2

  # The Flashpi API client.
  #
  #   flashpi = Flashpi::Client.new # reads FLASHPI_API_KEY
  #   invoice = flashpi.invoices.create({ ... })
  #
  # An `fp_test_` key issues in the SRI test environment (pruebas); an `fp_live_` key issues real
  # documents in production. Use it on servers only: the key must stay secret. A client is safe
  # to share between threads and keeps its connections open for the next requests: create one
  # and reuse it.
  class Client
    # @return [String] `"test"` for fp_test_ keys (SRI pruebas), `"live"` for fp_live_ keys (SRI
    #   production)
    attr_reader :environment
    # @return [Resources::Invoices] invoices (facturas)
    attr_reader :invoices
    # @return [Resources::CreditNotes] credit notes (notas de crédito)
    attr_reader :credit_notes
    # @return [Resources::DebitNotes] debit notes (notas de débito)
    attr_reader :debit_notes
    # @return [Resources::PurchaseSettlements] purchase settlements (liquidaciones de compra)
    attr_reader :purchase_settlements
    # @return [Resources::Waybills] waybills (guías de remisión)
    attr_reader :waybills
    # @return [Resources::Withholdings] withholding receipts (comprobantes de retención)
    attr_reader :withholdings
    # @return [Resources::Documents] every issued document: search, XML, RIDE (PDF) and email
    attr_reader :documents
    # @return [Resources::Issuers] issuers (RUCs) with their establishments, emission points and
    #   certificates
    attr_reader :issuers
    # @return [Resources::IssuerOnboardings] create an issuer from its .p12 certificate
    attr_reader :issuer_onboardings
    # @return [Resources::WebhookEndpoints] the URLs Flashpi sends events to
    attr_reader :webhook_endpoints
    # @return [Resources::Events] events of documents, certificates and email sending
    attr_reader :events
    # @return [Resources::Status] the API's status
    attr_reader :status

    # Creates a client.
    #
    # @param api_key [String, nil] the API key (`fp_test_...` or `fp_live_...`); defaults to the
    #   FLASHPI_API_KEY environment variable
    # @param base_url [String, nil] the API's address (default https://api.flashpi.com.ec)
    # @param timeout [Integer, Float, nil] seconds each attempt of a request may take, from
    #   sending it to reading the whole answer (default 60). Issuing with
    #   `options: { waitForAuthorization: true }` raises it to the wait plus 15 seconds. Only a
    #   DNS lookup can run past it.
    # @param max_retries [Integer, nil] retries after network errors, timeouts, 429 and 5xx
    #   (default 2; 0 turns them off)
    # @param language [String, Symbol, nil] language of the API's messages: `"en"` (default) or
    #   `"es"`. Error codes do not change.
    # @param default_headers [Hash{String => String}, nil] headers sent with every request (not
    #   `Idempotency-Key`: that one is per request)
    # @raise [Flashpi::Error] for a missing or bad API key, base URL, timeout or max_retries
    def initialize(api_key: nil, base_url: nil, timeout: nil, max_retries: nil, language: nil, default_headers: nil)
      config = Internal::Settings.configure(api_key, base_url:, timeout:, max_retries:, language:, default_headers:)
      @environment = config.api_key.start_with?("fp_test_") ? "test" : "live"
      @transport = Internal::Transport.new(config.base_url)
      @engine = Internal::Engine.new(config, @transport)
      @invoices = Resources::Invoices.new(@engine)
      @credit_notes = Resources::CreditNotes.new(@engine)
      @debit_notes = Resources::DebitNotes.new(@engine)
      @purchase_settlements = Resources::PurchaseSettlements.new(@engine)
      @waybills = Resources::Waybills.new(@engine)
      @withholdings = Resources::Withholdings.new(@engine)
      @documents = Resources::Documents.new(@engine)
      @issuers = Resources::Issuers.new(@engine)
      @issuer_onboardings = Resources::IssuerOnboardings.new(@engine)
      @webhook_endpoints = Resources::WebhookEndpoints.new(@engine)
      @events = Resources::Events.new(@engine)
      @status = Resources::Status.new(@engine)
    end

    # Verify the signature of the webhooks you receive (no API key needed).
    #
    # @return [Module] {Flashpi::Webhooks}
    def webhooks
      Webhooks
    end

    # @return [String] the API's address
    def base_url
      @engine.config.base_url
    end

    # Closes the connections kept open for the next requests. The client can still be used: it
    # opens new ones.
    #
    # @return [nil]
    def close
      @transport.close
    end

    # Never the API key.
    def inspect
      "#<#{self.class.name} environment=#{environment.inspect} base_url=#{base_url.inspect}>"
    end
    alias to_s inspect
  end
end
