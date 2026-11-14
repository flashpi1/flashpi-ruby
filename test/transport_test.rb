# frozen_string_literal: true

require_relative "test_helper"

# The net/http transport against a real local server: one deadline per attempt, kept-alive
# connections, network failures and the hooks into net/http it relies on.
class TransportTest < Minitest::Test
  include Support

  def setup
    @servers = []
  end

  def teardown
    @servers.each(&:close)
  end

  def serve(&)
    server = LocalServer.new(&)
    @servers << server
    server
  end

  def client(server, **settings)
    Flashpi::Client.new(api_key: TEST_KEY, base_url: server.url, **settings)
  end

  def json(socket, body = { ok: true }, headers = {})
    LocalServer.respond(socket, 200, JSON.generate(body), { "content-type" => "application/json" }.merge(headers))
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    @elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  PROXY_VARIABLES = %w[http_proxy HTTP_PROXY https_proxy HTTPS_PROXY no_proxy NO_PROXY REQUEST_METHOD].freeze

  def with_env(values)
    names = PROXY_VARIABLES | values.keys
    saved = names.to_h { |name| [name, ENV.fetch(name, nil)] }
    names.each { |name| values[name].nil? ? ENV.delete(name) : ENV.store(name, values[name]) }
    yield
  ensure
    saved.each { |name, value| value.nil? ? ENV.delete(name) : ENV.store(name, value) }
  end

  def gzip(text)
    output = StringIO.new
    writer = Zlib::GzipWriter.new(output)
    writer.write(text)
    writer.close
    output.string
  end

  def test_retries_an_answer_cut_before_its_content_length
    calls = 0
    server = serve do |_request, socket|
      calls += 1
      if calls == 1
        socket.write("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n%PDF-cut")
        :close
      else
        LocalServer.respond(socket, 200, "%PDF-#{"x" * 95}")
      end
    end
    assert_equal "%PDF-#{"x" * 95}", client(server).documents.pdf("doc")
    assert_equal 2, server.received.size
    cut = serve do |_request, socket|
      socket.write("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n{\"ok\"")
      :close
    end
    assert_raises(Flashpi::APIConnectionError) { client(cut, max_retries: 0).status.get }
  end

  def test_refuses_a_gzip_answer_that_ends_early
    whole = gzip('{"zipped":true}')
    server = serve do |_request, socket|
      LocalServer.respond(socket, 200, whole[0..-6], { "content-encoding" => "gzip" })
    end
    assert_raises(Flashpi::APIConnectionError) { client(server, max_retries: 0).status.get }
    assert_equal "gzip", server.received.first.headers["accept-encoding"]
  end

  def test_keeps_an_accept_encoding_of_the_caller
    server = serve { |_request, socket| json(socket) }
    client(server).status.get(extra_headers: { "Accept-Encoding" => "identity" })
    assert_equal "identity", server.received.first.headers["accept-encoding"]
  end

  def test_reads_response_headers_as_utf8_text
    server = serve { |_request, socket| json(socket, { ok: true }, { "x-request-id" => "req_ñ" }) }
    result = client(server).status.with_response.get
    assert_equal "req_ñ", result.request_id
    assert_equal Encoding::UTF_8, result.request_id.encoding
  end

  def test_goes_through_the_https_proxy_of_the_environment
    proxy = serve do |_request, socket|
      LocalServer.respond(socket, 502)
      :close
    end
    %w[https_proxy HTTPS_PROXY].each do |name|
      with_env(name => "http://user:p%40ss@127.0.0.1:#{proxy.port}") do
        flashpi = Flashpi::Client.new(api_key: TEST_KEY, base_url: "https://api.flashpi.invalid", max_retries: 0)
        assert_raises(Flashpi::APIConnectionError) { flashpi.status.get }
      end
      request = proxy.received.first
      assert_equal %w[CONNECT api.flashpi.invalid:443], [request.http_method, request.target]
      assert_equal "Basic #{["user:p@ss"].pack("m0")}", request.headers["proxy-authorization"]
    end
  end

  def test_leaves_out_the_proxy_of_another_scheme_no_proxy_hosts_and_loopback
    proxy = serve { |_request, socket| LocalServer.respond(socket, 502) }
    [{ "http_proxy" => proxy.url }, { "https_proxy" => proxy.url, "no_proxy" => "example.com, .flashpi.invalid" },
     { "https_proxy" => proxy.url, "NO_PROXY" => "*" }].each do |variables|
      with_env(variables) do
        flashpi = Flashpi::Client.new(api_key: TEST_KEY, base_url: "https://api.flashpi.invalid", max_retries: 0)
        error = assert_raises(Flashpi::APIConnectionError) { flashpi.status.get }
        refute_includes error.message, "502"
      end
    end
    assert_empty proxy.received
    server = serve { |_request, socket| json(socket) }
    with_env("http_proxy" => proxy.url) { client(server).status.get }
    assert_equal 1, server.received.size
    assert_empty proxy.received
  end

  def test_refuses_a_proxy_url_it_cannot_use_without_showing_it
    ["http://deploy:s3cret pass@proxy.corp:3128", "https://proxy.corp:3128", "socks5://proxy.corp:1080",
     "http://"].each do |value|
      with_env("https_proxy" => value) do
        error = assert_raises(Flashpi::Error) { Flashpi::Client.new(api_key: TEST_KEY) }
        assert_equal "The https_proxy environment variable is not an http:// proxy URL", error.message
        assert_nil error.cause
      end
    end
    with_env("https_proxy" => "127.0.0.1:9") { Flashpi::Client.new(api_key: TEST_KEY) }
  end

  def test_keeps_the_deadline_while_a_proxy_trickles_its_answer_to_connect
    proxy = serve do |_request, socket|
      "HTTP/1.1 200 Connection established\r\nx-slow: #{"a" * 40}\r\n\r\n".each_char do |char|
        socket.write(char)
        sleep 0.05
      end
      sleep 3
    end
    with_env("https_proxy" => proxy.url) do
      flashpi = Flashpi::Client.new(api_key: TEST_KEY, base_url: "https://api.flashpi.invalid", timeout: 0.5,
                                    max_retries: 0)
      assert_raises(Flashpi::APITimeoutError) { elapsed { flashpi.status.get } }
    end
    assert_operator @elapsed, :<, 1.5
  end

  def test_does_not_reuse_an_idle_connection_that_has_something_to_read
    server = serve do |_request, socket|
      json(socket)
      sleep 0.05
      socket.write("HTTP/1.1 200 OK\r\n")
      nil
    end
    flashpi = client(server, max_retries: 0)
    flashpi.status.get
    sleep 0.2
    assert_equal({ ok: true }, flashpi.status.get)
    assert_equal [1, 2], server.received.map(&:connection)
  end

  def test_lets_a_callers_own_timeout_stop_the_call
    server = serve do |_request, socket|
      sleep 0.6
      json(socket)
    end
    [Timeout::Error, Class.new(Timeout::Error)].each do |error_class|
      assert_raises(error_class) { Timeout.timeout(0.2, error_class) { client(server).invoices.create({}) } }
    end
    sleep 0.1
    assert_equal 2, server.received.size
  end

  def test_sends_the_request_and_reads_the_answer
    server = serve { |_request, socket| json(socket, { id: "a" }, { "x-request-id" => "req_1" }) }
    result = client(server).invoices.with_response.create({ total: "1.15" }, idempotency_key: "k-1")
    assert_equal({ id: "a" }, result.data)
    assert_equal "req_1", result.request_id
    request = server.received.first
    assert_equal ["POST", "/v1/invoices"], [request.http_method, request.target]
    assert_equal '{"total":"1.15"}', request.body
    assert_equal "Bearer #{TEST_KEY}", request.headers["authorization"]
    assert_equal "k-1", request.headers["idempotency-key"]
    assert_equal "application/json", request.headers["content-type"]
    assert_equal "flashpi-ruby/#{Flashpi::VERSION}", request.headers["user-agent"]
  end

  def test_sends_a_post_without_a_body_with_no_content_type
    server = serve { |_request, socket| json(socket) }
    client(server).webhook_endpoints.verify("ep_1")
    request = server.received.first
    assert_equal "0", request.headers["content-length"]
    assert_nil request.headers["content-type"]
  end

  def test_sends_header_values_outside_ascii_as_utf8
    server = serve { |_request, socket| json(socket) }
    client(server, default_headers: { "X-Store" => "Panadería Ñandú" }).status.get
    assert_equal "Panadería Ñandú", server.received.first.headers["x-store"].force_encoding(Encoding::UTF_8)
  end

  def test_keeps_the_connection_alive_between_requests
    server = serve { |_request, socket| json(socket) }
    flashpi = client(server)
    3.times { flashpi.status.get }
    assert_equal [1, 1, 1], server.received.map(&:connection)
    flashpi.close
    flashpi.status.get
    assert_equal [2], server.received.map(&:connection)
  end

  def test_opens_a_new_connection_when_the_server_closed_the_last_one
    server = serve do |_request, socket|
      json(socket, { ok: true }, { "connection" => "close" })
      :close
    end
    flashpi = client(server)
    2.times { flashpi.status.get }
    assert_equal [1, 2], server.received.map(&:connection)
  end

  def test_wraps_the_socket_of_each_connection_to_keep_the_deadline
    server = serve { |_request, socket| json(socket) }
    flashpi = client(server)
    flashpi.status.get
    idle = flashpi.instance_variable_get(:@transport).instance_variable_get(:@idle)
    assert_equal 1, idle.size
    socket = idle.first.instance_variable_get(:@socket)
    assert_instance_of Net::BufferedIO, socket
    assert_instance_of Flashpi::Internal::DeadlineSocket, socket.io
    assert_equal 0, idle.first.max_retries
  end

  def test_times_out_an_answer_that_trickles_in_past_the_deadline
    server = serve do |_request, socket|
      socket.write("HTTP/1.1 200 OK\r\ncontent-length: 20\r\n\r\n")
      20.times do
        socket.write("x")
        sleep 0.1
      end
    end
    error = assert_raises(Flashpi::APITimeoutError) { elapsed { client(server, timeout: 0.5, max_retries: 0).status.get } }
    assert_match(%r{\AGET http://127.0.0.1:\d+/v1/status timed out after 0.5 seconds\z}, error.message)
    assert_operator @elapsed, :<, 1.2
  end

  def test_times_out_headers_that_trickle_in_past_the_deadline
    server = serve do |_request, socket|
      "HTTP/1.1 200 OK\r\nx-slow: #{"a" * 30}\r\n".each_char do |char|
        socket.write(char)
        sleep 0.05
      end
    end
    assert_raises(Flashpi::APITimeoutError) { elapsed { client(server, timeout: 0.5, max_retries: 0).status.get } }
    assert_operator @elapsed, :<, 1.2
  end

  def test_times_out_a_server_that_never_answers_and_retries_with_the_same_key
    server = serve { |_request, _socket| sleep 5 }
    error = assert_raises(Flashpi::APITimeoutError) do
      elapsed { client(server, timeout: 0.3, max_retries: 1).invoices.create({}) }
    end
    requests = server.received
    assert_equal 2, requests.size
    assert_equal 1, requests.map { |request| request.headers["idempotency-key"] }.uniq.size
    assert_equal requests.first.headers["idempotency-key"], error.idempotency_key
    assert_operator @elapsed, :<, 2.5
  end

  def test_reads_an_answer_that_arrives_in_time
    server = serve do |_request, socket|
      socket.write("HTTP/1.1 200 OK\r\ncontent-length: 11\r\ncontent-type: application/json\r\n\r\n")
      sleep 0.1
      socket.write('{"ok":true}')
    end
    assert_equal({ ok: true }, client(server, timeout: 2).status.get)
  end

  def test_decodes_a_compressed_answer
    server = serve do |request, socket|
      body = StringIO.new
      gzip = Zlib::GzipWriter.new(body)
      gzip.write('{"zipped":true}')
      gzip.close
      encoding = request.headers["accept-encoding"].to_s.include?("gzip") ? "gzip" : "identity"
      LocalServer.respond(socket, 200, body.string, { "content-encoding" => encoding })
    end
    assert_equal({ zipped: true }, client(server).status.get)
  end

  def test_raises_a_connection_error_when_nothing_listens
    port = TCPServer.open("127.0.0.1", 0) { |probe| probe.addr[1] }
    flashpi = Flashpi::Client.new(api_key: TEST_KEY, base_url: "http://127.0.0.1:#{port}", max_retries: 0)
    error = assert_raises(Flashpi::APIConnectionError) { flashpi.status.get }
    refute_kind_of Flashpi::APITimeoutError, error
    assert_match(%r{\AGET http://127.0.0.1:#{port}/v1/status failed: }, error.message)
  end

  def test_raises_a_connection_error_when_the_server_hangs_up
    server = serve { |_request, _socket| :close }
    assert_raises(Flashpi::APIConnectionError) { client(server, max_retries: 0).status.get }
  end

  def test_raises_a_connection_error_for_an_answer_that_is_not_http
    server = serve do |_request, socket|
      socket.write("SSH-2.0-OpenSSH\r\n\r\n")
      :close
    end
    assert_raises(Flashpi::APIConnectionError) { client(server, max_retries: 0).status.get }
  end

  def test_does_not_follow_redirects
    server = serve { |_request, socket| LocalServer.respond(socket, 302, "", { "location" => "http://example.com/" }) }
    error = assert_raises(Flashpi::APIError) { client(server).status.get }
    assert_equal 302, error.status
    assert_equal 1, server.received.size
  end

  def test_times_out_a_tls_handshake_that_never_ends
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    holder = Thread.new do
      held = listener.accept
      sleep 3
      held.close
    rescue IOError
      nil
    end
    flashpi = Flashpi::Client.new(api_key: TEST_KEY, base_url: "https://127.0.0.1:#{port}", timeout: 0.4,
                                  max_retries: 0)
    assert_raises(Flashpi::APITimeoutError) { elapsed { flashpi.status.get } }
    assert_operator @elapsed, :<, 1.5
  ensure
    listener&.close
    holder&.kill
  end

  def test_sends_a_certificate_upload_as_multipart
    server = serve { |_request, socket| json(socket, { id: "cert" }) }
    p12 = "\x30\x82\x01\x02\r\n--x".b
    client(server).issuers.certificates.upload("iss_1",
                                               { file: StringIO.new(p12), password: "clave ñ", filename: 'a"b.p12' })
    request = server.received.first
    boundary = request.headers["content-type"][/boundary=(.+)\z/, 1]
    assert_match(/\Aflashpi-\h{32}\z/, boundary)
    body = request.body.b
    assert_includes body, "name=\"password\"\r\n\r\nclave ñ\r\n".b
    assert_includes body,
                    "name=\"file\"; filename=\"a%22b.p12\"\r\nContent-Type: application/x-pkcs12\r\n\r\n#{p12}\r\n".b
    assert body.end_with?("--#{boundary}--\r\n")
    assert_operator body.index("name=\"password\""), :<, body.index("name=\"file\"")
  end

  def test_shares_a_client_between_threads
    server = serve { |request, socket| json(socket, { path: request.target }) }
    flashpi = client(server)
    paths = Array.new(8) { |index| Thread.new { flashpi.documents.get("doc-#{index}")[:path] } }.map(&:value)
    assert_equal Array.new(8) { |index| "/v1/documents/doc-#{index}" }, paths
  end

  def test_drops_the_parents_connections_after_a_fork
    server = serve { |_request, socket| json(socket) }
    flashpi = client(server)
    flashpi.status.get
    transport = flashpi.instance_variable_get(:@transport)
    transport.instance_variable_set(:@pid, -1)
    flashpi.status.get
    assert_equal [1, 2], server.received.map(&:connection)
    assert_nil transport.close
  end
end
