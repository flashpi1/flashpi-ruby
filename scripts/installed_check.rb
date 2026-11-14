# frozen_string_literal: true

# Uses the installed gem the way an application would. CI runs it with a Ruby whose GEM_HOME
# holds only the gem, outside Bundler:
#
#   GEM_HOME=/tmp/clean gem install --local flashpi-0.1.0.gem
#   GEM_HOME=/tmp/clean GEM_PATH=/tmp/clean ruby scripts/installed_check.rb
#
# It fails when flashpi is loaded from this repository instead of the installed gem, when the gem
# lacks its signatures, or when a call against a local server does not work.

require "socket"

ROOT = File.expand_path("..", __dir__)
KEY = "fp_test_installed_check"

require "flashpi"

def serve
  server = TCPServer.new("127.0.0.1", 0)
  Thread.new do
    socket = server.accept
    request = +""
    request << socket.gets("\r\n").to_s until request.end_with?("\r\n\r\n")
    body = request.match?(/^authorization: Bearer #{KEY}\r$/i) ? '{"status":"operational"}' : '{"code":"x"}'
    status = body.include?("operational") ? "200 OK" : "401 Unauthorized"
    socket.write("HTTP/1.1 #{status}\r\ncontent-type: application/json\r\ncontent-length: #{body.bytesize}\r\n" \
                 "connection: close\r\n\r\n#{body}")
    socket.close
  end
  server.addr[1]
end

problems = []
location = $LOADED_FEATURES.find { |feature| feature.end_with?("/flashpi.rb") }.to_s
spec = Gem.loaded_specs["flashpi"]
if location.start_with?("#{ROOT}/") || spec.nil?
  warn "flashpi was loaded from #{location}, not from an installed gem"
  exit 1
end
version = spec.version.to_s
problems << "Flashpi::VERSION is #{Flashpi::VERSION}, the gem #{version}" unless version == Flashpi::VERSION
problems << "the gem has runtime dependencies" unless spec.runtime_dependencies.empty?
%w[sig/flashpi.rbs sig/flashpi/types.rbs sig/manifest.yaml].each do |file|
  problems << "#{file} is missing" unless File.file?(File.join(spec.full_gem_path, file))
end
port = serve
client = Flashpi::Client.new(api_key: KEY, base_url: "http://127.0.0.1:#{port}")
problems << "the client did not read the status" unless client.status.get == { status: "operational" }
problems.each { |problem| warn problem }
exit 1 unless problems.empty?

puts "flashpi #{spec.version} works from #{spec.full_gem_path} on Ruby #{RUBY_VERSION}"
