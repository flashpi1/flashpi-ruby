# frozen_string_literal: true

module Flashpi
  module Resources
    # Creates an issuer from its .p12: upload the certificate, wait while the onboarding is
    # `verifying` until it is `ready` (Flashpi reads the holder, RUC and SRI data) or `rejected`,
    # review the prefill, then complete it.
    #
    # Needs an account-scoped API key with read_write access.
    class IssuerOnboardings < Internal::Resource
      response_methods :create, :get, :complete

      # Starts an onboarding with a .p12 and its password. It starts `verifying`.
      #
      # @param upload [Hash] `{ file: String or IO, password: String, filename: String }`
      # @return [Hash{Symbol => Object}] the onboarding
      def create(upload, **options)
        form = Internal::Multipart.certificate(upload)
        send_request(operation(:post, "/v1/issuer-onboardings", multipart: form, options:))
      end

      # Retrieves an onboarding, to follow it while it is `verifying`.
      #
      # @return [Hash{Symbol => Object}] the onboarding
      def get(onboarding_id, **options)
        send_request(operation(:get, "/v1/issuer-onboardings/{}", onboarding_id, options:))
      end

      # Completes a `ready` onboarding.
      #
      # - For a new RUC, `body` is the issuer to create (as in `issuers.create`): `legalName`,
      #   `headOfficeAddress` and `taxProfile` are required. Build it from `onboarding[:prefill]`;
      #   the API does not apply the prefill by itself.
      # - When `onboarding[:existingIssuer]` is set, `body` can be left out (`{}` is sent): the
      #   certificate is added to that issuer for both modes (a renewal) and the issuer is left as
      #   it is.
      # - Send `ruc` when `onboarding[:rucNeedsConfirmation]` is true.
      #
      # @return [Hash{Symbol => Object}] the completed onboarding, with its issuer
      def complete(onboarding_id, body = nil, **options)
        send_request(
          operation(:post, "/v1/issuer-onboardings/{}/complete", onboarding_id, body: body.nil? ? {} : body, options:)
        )
      end
    end
  end
end
