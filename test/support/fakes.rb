# frozen_string_literal: true

# Test helpers: a fake transport that answers from a queue and records what it was sent, and a
# fake clock for the waits between retries.
module Support
  TEST_KEY = "fp_test_#{"a" * 16}#{"b" * 32}".freeze
  LIVE_KEY = "fp_live_#{"a" * 16}#{"b" * 32}".freeze
  ID = "019a1b2c-3d4e-7f60-8a1b-2c3d4e5f6a7b"
  OTHER_ID = "019a1b2c-3d4e-7f60-8a1b-2c3d4e5f6a7c"

  # A clock whose sleeps advance it at once.
  class FakeClock
    attr_reader :sleeps, :now
    attr_accessor :random

    def initialize
      @now = 1000.0
      @sleeps = []
      @random = 0.0
    end

    def advance(seconds)
      @now += seconds
    end

    def sleep(seconds)
      @sleeps << seconds
      @now += seconds
    end

    def rand
      @random
    end

    def elapsed
      @sleeps.sum
    end
  end

  # Stands for Internal::Transport: answers each attempt from a queue. A RawResponse is the
  # answer, an Exception is raised (an APIConnectionError like a network failure), and a Proc
  # answers dynamically with the attempt.
  class FakeTransport
    attr_reader :sent

    def initialize(replies)
      @replies = replies
      @sent = []
    end

    def perform(attempt)
      @sent << attempt
      raise Minitest::Assertion, "Unexpected request #{attempt.verb} #{attempt.url}" if @replies.empty?

      reply = @replies.shift
      reply = reply.call(attempt) if reply.is_a?(Proc)
      raise reply if reply.is_a?(Exception)

      reply
    end

    def close
      nil
    end

    def left
      @replies.size
    end
  end

  module_function

  # A JSON answer.
  def json_response(body, status = 200, headers = {})
    Flashpi::Internal::RawResponse.new(
      status,
      { "content-type" => "application/json", "x-request-id" => "req_123" }.merge(headers),
      JSON.generate(body).b
    )
  end

  # A Problem Details answer like the API's.
  def problem(status, code, extra = {}, headers = {})
    body = {
      type: "https://flashpi.com.ec/docs/en/errors/#{code}", title: "Problem", status:,
      detail: "Detail of #{code}", instance: "/v1/test", code:, errors: [], requestId: "req_problem"
    }.merge(extra)
    Flashpi::Internal::RawResponse.new(
      status,
      { "content-type" => "application/problem+json; charset=utf-8", "x-request-id" => "req_problem" }.merge(headers),
      JSON.generate(body).b
    )
  end

  # An answer with any body.
  def raw(status, body = "", headers = {})
    Flashpi::Internal::RawResponse.new(status, headers, body.b)
  end

  # A list answer.
  def page(data, next_cursor = nil)
    json_response({ data:, pagination: { nextCursor: next_cursor, hasMore: !next_cursor.nil? } })
  end

  # A minimal document as the API returns it.
  def document_body(document_id = ID, status = "processing")
    { id: document_id, type: "invoice", status:, environment: "test", accessKey: "1" * 49 }
  end

  # A network failure as the transport raises it.
  def network_error(message = "fetch failed")
    ->(attempt) { Flashpi::APIConnectionError.new("#{attempt.verb} #{attempt.url} failed: #{message}") }
  end

  # An attempt that times out after `seconds` on the fake clock.
  def timeout_after(clock, seconds)
    lambda do |attempt|
      clock.advance(seconds)
      Flashpi::APITimeoutError.new("#{attempt.verb} #{attempt.url} timed out after #{seconds} seconds")
    end
  end

  # The JSON body an attempt sent, with Symbol keys.
  def sent_json(attempt)
    JSON.parse(attempt.content, symbolize_names: true)
  end

  # A client whose requests go to a fake transport, with a fake clock.
  class Mock
    attr_reader :client, :transport, :clock

    def initialize(replies, **settings)
      @client = Flashpi::Client.new(api_key: TEST_KEY, **settings)
      @transport = FakeTransport.new(replies)
      @clock = FakeClock.new
      engine = @client.instance_variable_get(:@engine)
      engine.transport = @transport
      engine.clock = @clock
    end

    def sent
      @transport.sent
    end
  end

  # A client on a fake transport, answering `replies` in order.
  def fake_api(*replies, **settings)
    Mock.new(replies, **settings)
  end
end

module Support
  module_function

  # The local variables of every method that raised while the block ran, as error trackers that
  # record them (Sentry's include_local_variables, Rollbar's locals) would see them, as text.
  def locals_at_raise
    captured = []
    trace = TracePoint.new(:raise) do |point|
      binding = point.binding
      next if binding.nil?

      captured << binding.local_variables.map { |name| "#{name}=#{binding.local_variable_get(name).inspect}" }.join(" ")
    end
    trace.enable do
      yield
    rescue StandardError
      nil
    end
    captured
  end
end
