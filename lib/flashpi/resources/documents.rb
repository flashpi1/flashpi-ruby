# frozen_string_literal: true

module Flashpi
  module Resources
    # Issues one document type. The answer is the document: `processing` right away (202), or,
    # with `options: { waitForAuthorization: true }`, its outcome once the SRI decides (200),
    # unless the wait ends first (202 with `processing` or `pending_sri`; follow it with webhooks
    # or `documents.get`).
    class DocumentIssuer < Internal::Resource
      # Seconds the API waits for the SRI in sync mode when `waitTimeoutSeconds` is not sent.
      DEFAULT_WAIT_SECONDS = 15
      # Time on top of the sync wait for Flashpi to build, sign and answer.
      SYNC_MARGIN_SECONDS = 15

      response_methods :create

      # The shortest per-attempt timeout for issuing `body`, in seconds.
      #
      # In sync mode (`options.waitForAuthorization`) the API holds the request for up to
      # `waitTimeoutSeconds` (15 by default) while the SRI decides, so each attempt waits at least
      # that plus 15 seconds. Otherwise 0: the client's timeout applies.
      #
      # @return [Float]
      def self.sync_timeout_floor(body)
        settings = member(body, :options)
        return 0.0 unless member(settings, :waitForAuthorization) == true

        wait = member(settings, :waitTimeoutSeconds)
        wait = DEFAULT_WAIT_SECONDS unless wait.is_a?(Integer) || (wait.is_a?(Float) && wait.finite?)
        (wait + SYNC_MARGIN_SECONDS).to_f
      end

      # @api private
      def self.member(value, name)
        return nil unless value.is_a?(Hash)

        value.key?(name) ? value[name] : value[name.to_s]
      end

      # Issues the document. Retries reuse the same Idempotency-Key, and when a retry finds the
      # document already created by an earlier attempt, its current state is returned instead of
      # an error.
      #
      # @param body [Hash] the document, with the API's camelCase keys
      # @return [Hash{Symbol => Object}] the document
      def create(body, **options)
        send_request(
          Internal::RequestSpec.new(
            http_method: :post, path: self.class::PATH, body:, options:,
            min_timeout: DocumentIssuer.sync_timeout_floor(body), recover_document: true
          )
        )
      end
    end

    # Invoices (facturas).
    class Invoices < DocumentIssuer
      PATH = "/v1/invoices"
    end

    # Credit notes (notas de crédito).
    class CreditNotes < DocumentIssuer
      PATH = "/v1/credit-notes"
    end

    # Debit notes (notas de débito).
    class DebitNotes < DocumentIssuer
      PATH = "/v1/debit-notes"
    end

    # Purchase settlements (liquidaciones de compra).
    class PurchaseSettlements < DocumentIssuer
      PATH = "/v1/purchase-settlements"
    end

    # Waybills (guías de remisión).
    class Waybills < DocumentIssuer
      PATH = "/v1/waybills"
    end

    # Withholding receipts (comprobantes de retención).
    class Withholdings < DocumentIssuer
      PATH = "/v1/withholdings"
    end

    # Every issued document, of any type: search, XML, RIDE (PDF) and email.
    class Documents < Internal::Resource
      XML_ACCEPT = "application/xml, application/problem+json"
      PDF_ACCEPT = "application/pdf, application/problem+json"
      XML_KINDS = %w[authorized signed unsigned].freeze

      response_methods :list, :get, :xml, :pdf, :send_email

      # Lists documents, newest first, with optional filters.
      #
      # @param params [Hash, nil] filters with the API's names (`status`, `issueDateFrom`, ...)
      # @return [Flashpi::Page]
      def list(params = nil, **options)
        paginate(Internal::RequestSpec.new(http_method: :get, path: "/v1/documents", query: params, options:))
      end

      # Retrieves a document with its tax status, SRI messages, RIDE and email state.
      #
      # @return [Hash{Symbol => Object}]
      def get(document_id, **options)
        send_request(Internal::RequestSpec.new(http_method: :get, path: Internal::Path.of("/v1/documents/{}", document_id),
                                               options:))
      end

      # The document's XML: the authorized one once the SRI authorizes it, otherwise the signed or
      # unsigned one (see `kind`).
      #
      # @return [Hash{Symbol => Object}] `{ xml: String, kind: "authorized" | "signed" | "unsigned" | nil }`
      def xml(document_id, **options)
        result = send_call(
          Internal::RequestSpec.new(http_method: :get, path: Internal::Path.of("/v1/documents/{}/xml", document_id),
                                    accept: XML_ACCEPT, response_type: :text, options:)
        )
        kind = result.headers["flashpi-xml-kind"]
        { xml: result.data, kind: XML_KINDS.include?(kind) ? kind : nil }
      end

      # The RIDE (the printable PDF) of an authorized document, as a binary String. Raises a
      # ConflictError with code `ride_not_available` while it is still being generated.
      #
      # @return [String]
      def pdf(document_id, **options)
        send_request(
          Internal::RequestSpec.new(http_method: :get, path: Internal::Path.of("/v1/documents/{}/pdf", document_id),
                                    accept: PDF_ACCEPT, response_type: :bytes, options:)
        )
      end

      # Emails the authorized document (RIDE and XML) again to the address of its request. The new
      # delivery shows in `email.deliveries`; daily limits apply (RateLimitError).
      #
      # @return [Hash{Symbol => Object}] the document
      def send_email(document_id, **options)
        send_request(
          Internal::RequestSpec.new(http_method: :post, path: Internal::Path.of("/v1/documents/{}/email", document_id),
                                    body: {}, options:)
        )
      end
    end
  end
end
