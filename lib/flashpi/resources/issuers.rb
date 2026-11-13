# frozen_string_literal: true

module Flashpi
  module Resources
    # Emission points (the second 3-digit series code) of an establishment.
    class EmissionPoints < Internal::Resource
      PATH = "/v1/issuers/{}/establishments/{}/emission-points"
      ITEM = "/v1/issuers/{}/establishments/{}/emission-points/{}"

      response_methods :create, :list, :get, :delete

      # @return [Hash{Symbol => Object}] the emission point
      def create(issuer_id, establishment_id, body, **options)
        send_request(operation(:post, PATH, issuer_id, establishment_id, body:, options:))
      end

      # Lists the emission points of an establishment, by code.
      #
      # @return [Flashpi::Page]
      def list(issuer_id, establishment_id, params = nil, **options)
        paginate(operation(:get, PATH, issuer_id, establishment_id, query: params, options:))
      end

      # @return [Hash{Symbol => Object}] the emission point
      def get(issuer_id, establishment_id, emission_point_id, **options)
        send_request(operation(:get, ITEM, issuer_id, establishment_id, emission_point_id, options:))
      end

      # Deletes an emission point that has no documents.
      #
      # @return [nil]
      def delete(issuer_id, establishment_id, emission_point_id, **options)
        send_request(
          operation(:delete, ITEM, issuer_id, establishment_id, emission_point_id, response_type: :none, options:)
        )
      end
    end

    # Establishments (the 3-digit series codes such as `001`) of an issuer.
    class Establishments < Internal::Resource
      PATH = "/v1/issuers/{}/establishments"
      ITEM = "/v1/issuers/{}/establishments/{}"

      response_methods :create, :list, :get, :update, :delete

      # @return [EmissionPoints] the emission points of an establishment
      attr_reader :emission_points

      def initialize(engine)
        super
        @emission_points = EmissionPoints.new(engine)
      end

      # @return [Hash{Symbol => Object}] the establishment
      def create(issuer_id, body, **options)
        send_request(operation(:post, PATH, issuer_id, body:, options:))
      end

      # Lists the establishments of an issuer, by code.
      #
      # @return [Flashpi::Page]
      def list(issuer_id, params = nil, **options)
        paginate(operation(:get, PATH, issuer_id, query: params, options:))
      end

      # @return [Hash{Symbol => Object}] the establishment
      def get(issuer_id, establishment_id, **options)
        send_request(operation(:get, ITEM, issuer_id, establishment_id, options:))
      end

      # Updates an establishment (only the fields sent).
      #
      # @return [Hash{Symbol => Object}] the establishment
      def update(issuer_id, establishment_id, body, **options)
        send_request(operation(:patch, ITEM, issuer_id, establishment_id, body:, options:))
      end

      # Deletes an establishment that has no documents, with its emission points.
      #
      # @return [nil]
      def delete(issuer_id, establishment_id, **options)
        send_request(operation(:delete, ITEM, issuer_id, establishment_id, response_type: :none, options:))
      end
    end

    # The .p12 certificates (firmas electrónicas) of an issuer.
    class Certificates < Internal::Resource
      PATH = "/v1/issuers/{}/certificates"
      ITEM = "/v1/issuers/{}/certificates/{}"

      response_methods :upload, :list, :get

      # Uploads a .p12 for the issuer, for the mode of the API key only (test or live). To renew
      # the certificate of both modes, start an `issuer_onboardings.create` with it instead.
      #
      # Flashpi checks it in the background: the certificate starts `processing`, then becomes
      # `accepted` (event `certificate.verified`, or `certificate.pending` while its revocation
      # status cannot be checked) or `rejected` (no event: follow it with `get` and read
      # `rejection`).
      #
      # @param upload [Hash] `{ file: String or IO, password: String, filename: String }`
      # @return [Hash{Symbol => Object}] the certificate
      def upload(issuer_id, upload, **options)
        form = Internal::Multipart.certificate(upload)
        send_request(operation(:post, PATH, issuer_id, multipart: form, options:))
      end

      # Lists the certificates of an issuer, newest first.
      #
      # @return [Flashpi::Page]
      def list(issuer_id, params = nil, **options)
        paginate(operation(:get, PATH, issuer_id, query: params, options:))
      end

      # @return [Hash{Symbol => Object}] the certificate
      def get(issuer_id, certificate_id, **options)
        send_request(operation(:get, ITEM, issuer_id, certificate_id, options:))
      end
    end

    # The issuers (RUCs) of the account, with their establishments, emission points and .p12
    # certificates. Needs an account-scoped API key with read_write access, also to read.
    class Issuers < Internal::Resource
      PATH = "/v1/issuers"
      ITEM = "/v1/issuers/{}"

      response_methods :create, :list, :get, :update, :delete

      # @return [Establishments] establishments of an issuer, with their emission points
      attr_reader :establishments
      # @return [Certificates] the .p12 certificates of an issuer
      attr_reader :certificates

      def initialize(engine)
        super
        @establishments = Establishments.new(engine)
        @certificates = Certificates.new(engine)
      end

      # Creates an issuer. To start from its .p12 instead, see `issuer_onboardings`.
      #
      # @return [Hash{Symbol => Object}] the issuer
      def create(body, **options)
        send_request(operation(:post, PATH, body:, options:))
      end

      # Lists the issuers, newest first.
      #
      # @return [Flashpi::Page]
      def list(params = nil, **options)
        paginate(operation(:get, PATH, query: params, options:))
      end

      # Retrieves an issuer.
      #
      # @return [Hash{Symbol => Object}] the issuer
      def get(issuer_id, **options)
        send_request(operation(:get, ITEM, issuer_id, options:))
      end

      # Updates an issuer's name, tax profile, branding or defaults (only the fields sent).
      #
      # @return [Hash{Symbol => Object}] the issuer
      def update(issuer_id, body, **options)
        send_request(operation(:patch, ITEM, issuer_id, body:, options:))
      end

      # Deletes an issuer that has no documents and no certificates, with its establishments,
      # emission points and issuer-scoped API keys. Otherwise 409 `resource_in_use`: certificates
      # cannot be deleted, so an issuer that ever had a .p12 (one from `issuer_onboardings` too)
      # stays.
      #
      # @return [nil]
      def delete(issuer_id, **options)
        send_request(operation(:delete, ITEM, issuer_id, response_type: :none, options:))
      end
    end
  end
end
