# frozen_string_literal: true

require "socket"

module Support
  # A small HTTP/1.1 server on 127.0.0.1 for the tests that need real sockets: each request is
  # handed to a block that writes the answer itself, as fast or as slowly as it likes. Connections
  # are kept alive until the client closes them or the block returns :close.
  class LocalServer
    Request = Struct.new(:http_method, :target, :headers, :body, :connection, keyword_init: true)

    attr_reader :requests, :port

    def initialize(&handler)
      @handler = handler
      @server = TCPServer.new("127.0.0.1", 0)
      @port = @server.addr[1]
      @requests = Queue.new
      @connections = 0
      @threads = []
      @acceptor = Thread.new { accept }
    end

    def url
      "http://127.0.0.1:#{port}"
    end

    def received
      list = []
      list << @requests.pop until @requests.empty?
      list
    end

    def close
      @server.close
      @acceptor.join(1)
      @threads.each { |thread| thread.kill.join(1) }
    end

    # Writes a whole answer.
    def self.respond(socket, status, body = "", headers = {})
      head = "HTTP/1.1 #{status} X\r\n"
      { "content-length" => body.bytesize.to_s }.merge(headers).each { |name, value| head << "#{name}: #{value}\r\n" }
      socket.write("#{head}\r\n#{body}")
    end

    private

    def accept
      loop do
        socket = @server.accept
        @connections += 1
        number = @connections
        @threads << Thread.new { serve(socket, number) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(socket, number)
      loop do
        request = read_request(socket, number)
        break if request.nil?

        @requests << request
        break if @handler.call(request, socket) == :close
      end
    rescue IOError, SystemCallError
      nil
    ensure
      socket.close unless socket.closed?
    end

    def read_request(socket, number)
      line = socket.gets("\r\n")
      return nil if line.nil?

      http_method, target = line.split
      headers = {}
      while (header = socket.gets("\r\n")) && header != "\r\n"
        name, value = header.chomp("\r\n").split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      length = headers["content-length"].to_i
      body = length.positive? ? socket.read(length) : ""
      Request.new(http_method:, target:, headers:, body:, connection: number)
    end
  end
end
