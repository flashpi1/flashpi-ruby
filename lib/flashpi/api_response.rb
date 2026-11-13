# frozen_string_literal: true

module Flashpi
  # The data of a call together with the HTTP answer it came from, returned by the methods of a
  # resource's `with_response` view:
  #
  #   result = flashpi.documents.with_response.get(document_id)
  #   result.data[:status]
  #   result.status      # 200
  #   result.request_id  # share it with support
  class APIResponse
    # @return [Object] what the method returns
    attr_reader :data
    # @return [Integer] the HTTP status
    attr_reader :status
    # @return [Hash{String => String}] the response headers, by lowercase name
    attr_reader :headers
    # @return [String, nil] Flashpi's id of the request (`x-request-id`)
    attr_reader :request_id

    def initialize(data:, status:, headers:, request_id:)
      @data = data
      @status = status
      @headers = headers
      @request_id = request_id
      freeze
    end

    def inspect
      "#<#{self.class.name} status=#{status} request_id=#{request_id.inspect} data=#{(_ = data).inspect}>"
    end
  end
end
