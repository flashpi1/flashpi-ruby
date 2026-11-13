# frozen_string_literal: true

module Flashpi
  module Resources
    # Events: what happened to documents, certificates and email sending, newest first.
    class Events < Internal::Resource
      response_methods :list, :get

      # Lists events, optionally by type, issuer, document or certificate.
      #
      # @return [Flashpi::Page]
      def list(params = nil, **options)
        paginate(Internal::RequestSpec.new(http_method: :get, path: "/v1/events", query: params, options:))
      end

      # Retrieves an event: the same object its webhook delivered.
      #
      # @return [Hash{Symbol => Object}] the event
      def get(event_id, **options)
        send_request(Internal::RequestSpec.new(http_method: :get, path: Internal::Path.of("/v1/events/{}", event_id),
                                               options:))
      end
    end

    # The API's own status. It needs no API key.
    class Status < Internal::Resource
      response_methods :get

      # Whether Flashpi is operational.
      #
      # @return [Hash{Symbol => Object}]
      def get(**options)
        send_request(Internal::RequestSpec.new(http_method: :get, path: "/v1/status", options:))
      end
    end
  end
end
