# frozen_string_literal: true

module Flashpi
  # One page of a list, newest first (establishments and emission points: by code).
  #
  # It is Enumerable over every item of this page and the following ones, fetched as needed:
  #
  #   flashpi.documents.list({ status: "authorized" }).each do |document|
  #     puts document[:accessKey]
  #   end
  #
  # {#data}, {#has_next_page?} and {#next_page} move one page at a time.
  class Page
    include Enumerable

    # @return [Array<Hash{Symbol => Object}>] the items of this page
    attr_reader :data
    # @return [String, nil] the cursor of the next page, or nil on the last one
    attr_reader :next_cursor

    # @param body [Hash] the body of a list answer: `data` and `pagination`
    # @yieldparam cursor [String] the cursor of the next page
    # @yieldreturn [Page] the next page
    def initialize(body, &fetch_page)
      members = body.is_a?(Hash) ? body : {} #: Hash[untyped, untyped]
      data = members[:data]
      pagination = members[:pagination]
      unless data.is_a?(Array) && pagination.is_a?(Hash)
        raise Error,
              "The API answered a list without data and pagination"
      end

      @data = data
      @has_more = pagination[:hasMore] == true
      cursor = pagination[:nextCursor]
      @next_cursor = cursor.is_a?(String) ? cursor : nil
      @fetch_page = fetch_page
    end

    # @return [Boolean] whether more items follow this page
    def has_more? # rubocop:disable Naming/PredicatePrefix -- the API's hasMore
      @has_more
    end

    # @return [Boolean] whether {#next_page} will return a page
    def has_next_page? # rubocop:disable Naming/PredicatePrefix
      @has_more && !@next_cursor.nil?
    end

    # The next page (same filters and options), or nil after the last page.
    #
    # @return [Page, nil]
    def next_page
      cursor = @next_cursor
      fetch_page = @fetch_page
      return nil unless @has_more && cursor && fetch_page

      fetch_page.call(cursor)
    end

    # Yields every item of this page and of the following ones, fetching them as needed.
    #
    # @yieldparam item [Hash{Symbol => Object}]
    # @return [Enumerator] without a block
    def each(&block)
      return enum_for(:each) unless block

      page = self #: Page[untyped]
      loop do
        page.data.each(&block)
        following = page.next_page
        break if following.nil?

        page = following
      end
      self
    end

    def inspect
      "#<#{self.class.name} data=<#{data.size} items> has_more=#{@has_more} next_cursor=#{next_cursor.inspect}>"
    end
  end
end
