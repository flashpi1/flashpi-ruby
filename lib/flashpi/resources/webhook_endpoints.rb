# frozen_string_literal: true

module Flashpi
  module Resources
    # Deliveries of events to one endpoint.
    class WebhookDeliveries < Internal::Resource
      PATH = "/v1/webhook-endpoints/{}/deliveries"
      ITEM = "/v1/webhook-endpoints/{}/deliveries/{}"

      response_methods :list, :get, :replay

      # Lists deliveries, newest first, optionally by status, event type or event.
      #
      # @return [Flashpi::Page]
      def list(endpoint_id, params = nil, **options)
        paginate(operation(:get, PATH, endpoint_id, query: params, options:))
      end

      # Retrieves a delivery with its attempts.
      #
      # @return [Hash{Symbol => Object}] the delivery
      def get(endpoint_id, delivery_id, **options)
        send_request(operation(:get, ITEM, endpoint_id, delivery_id, options:))
      end

      # Sends the delivery's event again, with the same `webhook-id`.
      #
      # @return [Hash{Symbol => Object}] the delivery
      def replay(endpoint_id, delivery_id, **options)
        send_request(operation(:post, "#{ITEM}/replay", endpoint_id, delivery_id, options:))
      end
    end

    # The URLs Flashpi sends events to. Needs an account-scoped API key with read_write access.
    # To check the signature of a webhook you receive, use {Flashpi::Webhooks} instead.
    class WebhookEndpoints < Internal::Resource
      PATH = "/v1/webhook-endpoints"
      ITEM = "/v1/webhook-endpoints/{}"

      response_methods :create, :list, :get, :update, :delete, :get_secret, :rotate_secret, :verify

      # @return [WebhookDeliveries] the deliveries of an endpoint: attempts, answers and replays
      attr_reader :deliveries

      def initialize(engine)
        super
        @deliveries = WebhookDeliveries.new(engine)
      end

      # Creates an endpoint. It stays `pending_verification` until it answers the activation
      # challenge; read its secret with {#get_secret} first, then call {#verify} if needed.
      #
      # @return [Hash{Symbol => Object}] the endpoint
      def create(body, **options)
        send_request(operation(:post, PATH, body:, options:))
      end

      # Lists the endpoints, newest first.
      #
      # @return [Flashpi::Page]
      def list(params = nil, **options)
        paginate(operation(:get, PATH, query: params, options:))
      end

      # Retrieves an endpoint.
      #
      # @return [Hash{Symbol => Object}] the endpoint
      def get(endpoint_id, **options)
        send_request(operation(:get, ITEM, endpoint_id, options:))
      end

      # Updates the URL, events, payload mode, description or `disabled` (only the fields sent).
      #
      # @return [Hash{Symbol => Object}] the endpoint
      def update(endpoint_id, body, **options)
        send_request(operation(:patch, ITEM, endpoint_id, body:, options:))
      end

      # Deletes an endpoint.
      #
      # @return [nil]
      def delete(endpoint_id, **options)
        send_request(operation(:delete, ITEM, endpoint_id, response_type: :none, options:))
      end

      # The signing secret (`whsec_...`) and, during a rotation, when the previous one expires.
      #
      # @return [Hash{Symbol => Object}]
      def get_secret(endpoint_id, **options)
        send_request(operation(:get, "#{ITEM}/secret", endpoint_id, options:))
      end

      # Replaces the signing secret. The previous one keeps signing for
      # `previousSecretExpiresInHours` (24 by default, 0 to drop it at once). Read the new secret
      # with {#get_secret}.
      #
      # @return [Hash{Symbol => Object}] the endpoint
      def rotate_secret(endpoint_id, body = nil, **options)
        send_request(operation(:post, "#{ITEM}/rotate-secret", endpoint_id, body:, options:))
      end

      # Sends the activation challenge (`webhook_endpoint.verification`) to the endpoint again.
      #
      # @return [Hash{Symbol => Object}] the endpoint
      def verify(endpoint_id, **options)
        send_request(operation(:post, "#{ITEM}/verify", endpoint_id, options:))
      end
    end
  end
end
