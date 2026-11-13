# frozen_string_literal: true

require_relative "test_helper"

class PaginationTest < Minitest::Test
  include Support

  def test_returns_the_first_page
    api = fake_api(page([{ id: "a" }, { id: "b" }], "cur_2"))
    first = api.client.documents.list({ status: "authorized" })
    assert_equal(%w[a b], first.data.map { |item| item[:id] })
    assert_predicate first, :has_more?
    assert_predicate first, :has_next_page?
    assert_equal "cur_2", first.next_cursor
    assert_equal "/v1/documents?status=authorized", api.sent.first.target
  end

  def test_fetches_the_next_page_with_the_same_filters_and_options
    api = fake_api(page([{ id: "a" }], "cur_2"), page([{ id: "b" }]))
    first = api.client.documents.list({ status: "authorized", "cursor" => "old" }, language: "es", timeout: 9)
    second = first.next_page
    assert_equal(["b"], second.data.map { |item| item[:id] })
    refute_predicate second, :has_next_page?
    assert_nil second.next_page
    assert_equal "/v1/documents?status=authorized&cursor=cur_2", api.sent[1].target
    assert_equal "es", api.sent[1].headers["accept-language"]
    assert_in_delta(9.0, api.sent[1].timeout)
  end

  def test_iterates_every_item_across_pages
    api = fake_api(page([{ id: "a" }, { id: "b" }], "c2"), page([], "c3"), page([{ id: "c" }]))
    ids = api.client.events.list.map { |event| event[:id] }
    assert_equal %w[a b c], ids
    assert_equal 3, api.sent.size
  end

  def test_starts_from_a_given_cursor_and_encodes_query_values
    api = fake_api(page([]), page([]))
    api.client.documents.list({ cursor: "abc", limit: 50, issueDateFrom: Date.new(2026, 11, 1), issuerId: nil,
                                accessKey: "a b&c" })
    api.client.webhook_endpoints.deliveries.list(ID, { eventType: :"invoice.authorized", status: "failed" })
    assert_equal "/v1/documents?cursor=abc&limit=50&issueDateFrom=2026-11-01&accessKey=a+b%26c", api.sent[0].target
    assert_equal "/v1/webhook-endpoints/#{ID}/deliveries?eventType=invoice.authorized&status=failed",
                 api.sent[1].target
  end

  def test_writes_booleans_and_refuses_values_a_query_cannot_hold
    api = fake_api(page([]))
    api.client.events.list({ flag: true, other: false })
    assert_equal "/v1/events?flag=true&other=false", api.sent[0].target
    [{ status: [1] }, { status: { a: 1 } }, { limit: Float::NAN }, { 1 => "x" }].each do |params|
      assert_raises(TypeError, ArgumentError) { api.client.events.list(params) }
    end
  end

  def test_does_not_follow_a_page_that_says_has_more_without_a_cursor
    api = fake_api(json_response({ data: [{ id: "a" }], pagination: { hasMore: true, nextCursor: nil } }))
    first = api.client.issuers.list
    assert_predicate first, :has_more?
    refute_predicate first, :has_next_page?
    assert_equal(["a"], first.to_a.map { |item| item[:id] })
    assert_equal 1, api.sent.size
  end

  def test_exposes_the_response_of_the_first_page
    api = fake_api(page([{ id: "a" }], "c2"))
    result = api.client.issuers.with_response.list({ limit: 1 })
    assert_instance_of Flashpi::Page, result.data
    assert_equal "req_123", result.request_id
  end

  def test_refuses_a_list_answer_without_data_and_pagination
    [{ data: [] }, { pagination: {} }, [], { data: {}, pagination: {} }].each do |body|
      api = fake_api(json_response(body))
      assert_raises(Flashpi::Error) { api.client.events.list }
    end
  end

  def test_stops_when_the_caller_stops
    api = fake_api(page([{ id: "a" }, { id: "b" }], "c2"))
    events = api.client.events.list
    assert_equal(["a"], events.first(1).map { |event| event[:id] })
    assert_instance_of Enumerator, events.each
    assert_equal(%w[a b], events.each.take(2).map { |event| event[:id] })
    assert_equal 1, api.sent.size
  end

  def test_shows_its_size_not_its_items
    api = fake_api(page([{ id: "a" }], "c2"))
    assert_equal '#<Flashpi::Page data=<1 items> has_more=true next_cursor="c2">', api.client.events.list.inspect
  end
end
