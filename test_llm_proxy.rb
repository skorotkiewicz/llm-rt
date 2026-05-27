# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require_relative "llm_proxy"

class FakeUpstream
  attr_reader :port, :requests

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @running = true
    @thread = Thread.new { run }
  end

  def shutdown
    @running = false
    @server.close unless @server.closed?
    @thread.join(1)
  end

  private

  def run
    while @running
      socket = @server.accept
      Thread.new(socket) { |client| handle_client(client) }
    end
  rescue IOError
    nil
  end

  def handle_client(socket)
    request_line = socket.gets.to_s
    method, path, = request_line.split(/\s+/, 3)
    headers = read_headers(socket)
    body = socket.read(headers["content-length"].to_i).to_s
    @requests << { method: method, path: path, body: body, authorization: headers["authorization"] }

    response_body = JSON.generate(
      id: "chatcmpl-test",
      object: "chat.completion",
      created: Time.now.to_i,
      model: "gemma4",
      choices: [
        {
          index: 0,
          message: { role: "assistant", content: "upstream ok" },
          finish_reason: "stop"
        }
      ]
    )

    socket.write("HTTP/1.1 200 OK\r\n")
    socket.write("Content-Type: application/json\r\n")
    socket.write("Content-Length: #{response_body.bytesize}\r\n")
    socket.write("Connection: close\r\n")
    socket.write("\r\n")
    socket.write(response_body)
  ensure
    socket.close unless socket.closed?
  end

  def read_headers(socket)
    headers = {}

    while (line = socket.gets)
      line = line.chomp
      break if line.empty?

      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip if name && value
    end

    headers
  end
end

def assert(name, condition)
  return if condition

  raise "Assertion failed: #{name}"
end

def post_completion(port)
  uri = URI("http://127.0.0.1:#{port}/v1/chat/completions")
  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer user-a"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(
    model: "client-model",
    messages: [{ role: "user", content: "hello" }]
  )

  Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
end

begin
  upstream = FakeUpstream.new
  config = Config.new(
    "HOST" => "127.0.0.1",
    "PORT" => "1",
    "BASE_API_URL" => "http://127.0.0.1:#{upstream.port}/v1",
    "BASE_API_KEY" => "upstream-secret",
    "BASE_MODEL" => "gemma4",
    "MAX_TOKENS" => "1",
    "REFILL_TOKENS" => "1",
    "REFILL_INTERVAL_SECONDS" => "300"
  )
  server = HttpServer.new(host: "127.0.0.1", port: 0, app: ProxyApp.new(config, BucketStore.new(config)))
  thread = Thread.new { server.start }

  first = post_completion(server.port)
  assert("first request status", first.code == "200")
  assert("first request upstream body", JSON.parse(first.body).dig("choices", 0, "message", "content") == "upstream ok")
  assert("first request depleted bucket", first["X-RateLimit-Remaining"] == "0")

  upstream_request = upstream.requests.pop
  assert("upstream method", upstream_request[:method] == "POST")
  assert("upstream path", upstream_request[:path] == "/v1/chat/completions")
  assert("upstream auth", upstream_request[:authorization] == "Bearer upstream-secret")
  assert("upstream model rewrite", JSON.parse(upstream_request[:body])["model"] == "gemma4")

  second = post_completion(server.port)
  limit_message = JSON.parse(second.body).dig("choices", 0, "message", "content")
  assert("limit status", second.code == "200")
  assert("limit message", limit_message.include?("limit reached, wait 5 min"))
  assert("limit bucket remains empty", second["X-RateLimit-Remaining"] == "0")

  models_uri = URI("http://127.0.0.1:#{server.port}/v1/models")
  models = Net::HTTP.get_response(models_uri)
  assert("models status", models.code == "200")
  assert("models shape", JSON.parse(models.body)["object"] == "list")
  assert("models id", JSON.parse(models.body).dig("data", 0, "id") == "gemma4")

  puts "ok"
ensure
  server&.shutdown
  thread&.join(1)
  upstream&.shutdown
end
