# frozen_string_literal: true

module Flashpi
  module Internal
    # Base of every resource: resources only declare their operations as {RequestSpec}s.
    #
    #   class Documents < Internal::Resource
    #     response_methods :get
    #
    #     def get(document_id, **options)
    #       send_request(RequestSpec.new(http_method: :get, path: Path.of("/v1/documents/{}", document_id),
    #                                    options:))
    #     end
    #   end
    #
    # @api private
    class Resource
      # Declares the methods of the resource's `with_response` view: each runs the method and
      # returns an {APIResponse} with its data and the answer it came from.
      def self.response_methods(*names)
        view = Class.new(ResponseView)
        names.each do |name|
          # Defined at run time, so its body is outside Steep's view of the class.
          view.define_method(name) do |*args, **options, &block|
            capture { resource.public_send(name, *args, **options, &block) } # steep:ignore
          end
        end
        const_set(:WithResponse, view)
      end

      # @param engine [Engine]
      def initialize(engine)
        @engine = engine
      end

      # The same methods, returning an {APIResponse} with the HTTP status, headers and request id.
      #
      # @return [ResponseView]
      def with_response
        @with_response ||= self.class::WithResponse.new(self) # steep:ignore UnknownConstant
      end

      def inspect
        "#<#{self.class.name}>"
      end

      private

      # Sends the request (with its retries) and returns its data.
      def send_request(spec)
        send_call(spec).data
      end

      # Sends the request (with its retries) and returns its data with the answer.
      def send_call(spec)
        result = @engine.request(spec)
        ResponseView.record(result)
        result
      end

      # The first page of a list; iterating it walks every page.
      def paginate(spec)
        first = fetch_page(spec, spec)
        ResponseView.record(first)
        first.data
      end

      def fetch_page(spec, page_spec)
        result = @engine.request(page_spec)
        page = Page.new(result.data) do |cursor|
          query = (spec.query || {}).reject { |name, _| name.to_s == "cursor" }
          fetch_page(spec, spec.with_query(query.merge(cursor:))).data
        end
        APIResponse.new(data: page, status: result.status, headers: result.headers, request_id: result.request_id)
      end
    end

    # A resource's `with_response` view. The wrapped call records the last successful answer in a
    # fiber-local slot, so the resource's methods themselves stay unchanged.
    #
    # @api private
    class ResponseView
      SLOT = :__flashpi_response_capture

      # Keeps `result` for the `with_response` call running in this fiber, if any.
      def self.record(result)
        slot = Thread.current[SLOT]
        slot[:result] = result if slot
      end

      def initialize(resource)
        @resource = resource
      end

      def inspect
        "#<#{self.class.name}>"
      end

      private

      attr_reader :resource

      def capture
        previous = Thread.current[SLOT]
        slot = {} #: Hash[Symbol, APIResponse[untyped]]
        data = nil #: untyped
        Thread.current[SLOT] = slot
        begin
          data = yield
        ensure
          Thread.current[SLOT] = previous
        end
        result = slot[:result]
        raise Error, "The call sent no request, so there is no response to return" if result.nil?

        APIResponse.new(data:, status: result.status, headers: result.headers, request_id: result.request_id)
      end
    end
  end
end
