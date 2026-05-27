#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "socket"
require "time"
require "uri"

class Config
  attr_reader :host, :port, :upstream_base_url, :upstream_api_key, :base_model,
              :max_tokens, :refill_tokens, :refill_interval_seconds,
              :request_token_cost, :token_cost_mode, :response_token_reserve,
              :proxy_api_keys, :open_timeout, :read_timeout

  def initialize(env)
    @host = env_value(env, "HOST", default: "0.0.0.0")
    @port = integer(env_value(env, "PORT", default: "8888"), "PORT")
    @upstream_base_url = env_value(env, "UPSTREAM_BASE_URL", "BASE_API_URL", "base_api_url")
    @upstream_api_key = env_value(env, "UPSTREAM_API_KEY", "BASE_API_KEY", "base_api_key")
    @base_model = env_value(env, "UPSTREAM_MODEL", "BASE_MODEL", "base_model")

    @max_tokens = integer(env_value(env, "MAX_TOKENS", default: "10"), "MAX_TOKENS")
    @refill_tokens = integer(env_value(env, "REFILL_TOKENS", default: "2"), "REFILL_TOKENS")
    @refill_interval_seconds = integer(
      env_value(env, "REFILL_INTERVAL_SECONDS", default: "300"),
      "REFILL_INTERVAL_SECONDS"
    )

    @request_token_cost = integer(env_value(env, "REQUEST_TOKEN_COST", default: "1"), "REQUEST_TOKEN_COST")
    @token_cost_mode = env_value(env, "TOKEN_COST_MODE", default: "request")
    @response_token_reserve = integer(
      env_value(env, "RESPONSE_TOKEN_RESERVE", default: "256"),
      "RESPONSE_TOKEN_RESERVE"
    )
    @proxy_api_keys = env_value(env, "PROXY_API_KEYS", default: "")
                      .split(",")
                      .map(&:strip)
                      .reject(&:empty?)
    @open_timeout = integer(env_value(env, "OPEN_TIMEOUT", default: "10"), "OPEN_TIMEOUT")
    @read_timeout = integer(env_value(env, "READ_TIMEOUT", default: "120"), "READ_TIMEOUT")

    validate!
  end

  def authenticated_keys?
    !proxy_api_keys.empty?
  end

  private

  def env_value(env, *names, default: nil)
    names.each do |name|
      value = env[name]
      return value if value && !value.empty?
    end
    default
  end

  def integer(value, name)
    Integer(value)
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{name} must be an integer"
  end

  def validate!
    raise ArgumentError, "PORT must be between 1 and 65535" unless (1..65_535).cover?(port)
    raise ArgumentError, "MAX_TOKENS must be at least 1" if max_tokens < 1
    raise ArgumentError, "REFILL_TOKENS must be at least 1" if refill_tokens < 1
    if refill_interval_seconds < 1
      raise ArgumentError, "REFILL_INTERVAL_SECONDS must be at least 1"
    end
    raise ArgumentError, "REQUEST_TOKEN_COST must be at least 1" if request_token_cost < 1

    return if %w[request estimate].include?(token_cost_mode)

    raise ArgumentError, "TOKEN_COST_MODE must be request or estimate"
  end
end

class TokenBucket
  def initialize(max_tokens:, refill_tokens:, refill_interval_seconds:)
    @max_tokens = max_tokens
    @refill_tokens = refill_tokens
    @refill_interval_seconds = refill_interval_seconds
    @tokens = max_tokens
    @last_refill_at = monotonic_seconds
    @mutex = Mutex.new
  end

  def consume(cost)
    @mutex.synchronize do
      refill!

      if @tokens >= cost
        @tokens -= cost
        return snapshot(allowed: true, wait_seconds: 0)
      end

      snapshot(allowed: false, wait_seconds: seconds_until_available(cost))
    end
  end

  def state
    @mutex.synchronize do
      refill!
      snapshot(allowed: true, wait_seconds: 0)
    end
  end

  private

  def refill!
    now = monotonic_seconds
    intervals = ((now - @last_refill_at) / @refill_interval_seconds).floor
    return if intervals < 1

    @tokens = [@tokens + (intervals * @refill_tokens), @max_tokens].min
    @last_refill_at += intervals * @refill_interval_seconds
  end

  def seconds_until_available(cost)
    return 0 if @tokens >= cost
    return @refill_interval_seconds if cost > @max_tokens

    missing = cost - @tokens
    intervals = (missing.to_f / @refill_tokens).ceil
    next_refill_at = @last_refill_at + @refill_interval_seconds
    (next_refill_at + ((intervals - 1) * @refill_interval_seconds) - monotonic_seconds).ceil
  end

  def snapshot(allowed:, wait_seconds:)
    {
      allowed: allowed,
      limit: @max_tokens,
      remaining: @tokens,
      refill_tokens: @refill_tokens,
      refill_interval_seconds: @refill_interval_seconds,
      wait_seconds: [wait_seconds, 0].max
    }
  end

  def monotonic_seconds
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

class BucketStore
  def initialize(config)
    @config = config
    @buckets = {}
    @mutex = Mutex.new
  end

  def fetch(identity)
    @mutex.synchronize do
      @buckets[identity] ||= TokenBucket.new(
        max_tokens: @config.max_tokens,
        refill_tokens: @config.refill_tokens,
        refill_interval_seconds: @config.refill_interval_seconds
      )
    end
  end
end

class CostEstimator
  def initialize(config)
    @config = config
  end

  def cost(payload)
    return @config.request_token_cost unless @config.token_cost_mode == "estimate"
    return @config.request_token_cost unless payload.is_a?(Hash)

    prompt_tokens = (string_content(payload).join(" ").length / 4.0).ceil
    response_tokens = integer_field(payload, "max_completion_tokens") ||
                      integer_field(payload, "max_tokens") ||
                      @config.response_token_reserve
    [prompt_tokens + response_tokens, 1].max
  end

  private

  def integer_field(payload, key)
    value = payload[key]
    return unless value

    Integer(value)
  rescue ArgumentError, TypeError
    nil
  end

  def string_content(value)
    case value
    when String
      [value]
    when Array
      value.flat_map { |item| string_content(item) }
    when Hash
      value.flat_map do |key, item|
        next [] if key == "model"

        string_content(item)
      end
    else
      []
    end
  end
end

class HttpRequest
  attr_reader :request_method, :path, :query_string, :header, :body, :remote_ip

  def initialize(request_method:, target:, header:, body:, remote_ip:)
    uri = URI.parse(target)
    @request_method = request_method
    @path = uri.path.empty? ? "/" : uri.path
    @query_string = uri.query
    @header = header
    @body = body
    @remote_ip = remote_ip
  rescue URI::InvalidURIError
    @request_method = request_method
    @path = target.split("?").first
    @query_string = target.split("?", 2)[1]
    @header = header
    @body = body
    @remote_ip = remote_ip
  end

  def [](name)
    values = @header[name.downcase]
    values&.join(", ")
  end
end

class HttpResponse
  REASONS = {
    200 => "OK",
    204 => "No Content",
    400 => "Bad Request",
    401 => "Unauthorized",
    404 => "Not Found",
    502 => "Bad Gateway"
  }.freeze

  attr_accessor :status, :body

  def initialize
    @status = 200
    @headers = {}
    @body = ""
  end

  def []=(name, value)
    @headers[name] = value
  end

  def write(socket)
    response_body = status == 204 ? "" : body.to_s
    @headers["Content-Length"] = response_body.bytesize.to_s
    @headers["Connection"] = "close"

    socket.write("HTTP/1.1 #{status} #{REASONS.fetch(status, "OK")}\r\n")
    @headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
    socket.write("\r\n")
    socket.write(response_body) unless response_body.empty?
  end
end

class HttpServer
  attr_reader :port

  def initialize(host:, port:, app:)
    @server = TCPServer.new(host, port)
    @port = @server.addr[1]
    @app = app
    @running = true
  end

  def start
    while @running
      socket = @server.accept
      Thread.new(socket) { |client| handle_client(client) }
    end
  rescue IOError
    nil
  end

  def shutdown
    @running = false
    @server.close unless @server.closed?
  end

  private

  def handle_client(socket)
    request = read_request(socket)
    response = HttpResponse.new

    if request
      @app.call(request, response)
    else
      response.status = 400
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(error: { message: "Malformed HTTP request" })
    end

    response.write(socket)
  rescue StandardError => error
    warn "#{error.class}: #{error.message}"
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket)
    request_line = socket.gets
    return unless request_line

    method, target, _version = request_line.strip.split(/\s+/, 3)
    return unless method && target

    headers = read_headers(socket)
    body = read_body(socket, headers)

    HttpRequest.new(
      request_method: method,
      target: target,
      header: headers,
      body: body,
      remote_ip: socket.peeraddr[3]
    )
  end

  def read_headers(socket)
    headers = {}

    while (line = socket.gets)
      line = line.chomp
      break if line.empty?

      name, value = line.split(":", 2)
      next unless name && value

      headers[name.downcase] ||= []
      headers[name.downcase] << value.strip
    end

    headers
  end

  def read_body(socket, headers)
    length = headers["content-length"]&.first.to_i
    return "" if length <= 0

    socket.read(length).to_s
  end
end

class ProxyApp
  COMPLETION_PATHS = %w[/v1/chat/completions /v1/completions].freeze
  HOP_BY_HOP_HEADERS = %w[
    connection keep-alive proxy-authenticate proxy-authorization te trailer
    transfer-encoding upgrade host authorization content-length
  ].freeze
  HTTP_METHODS = {
    "DELETE" => Net::HTTP::Delete,
    "GET" => Net::HTTP::Get,
    "PATCH" => Net::HTTP::Patch,
    "POST" => Net::HTTP::Post,
    "PUT" => Net::HTTP::Put
  }.freeze

  def initialize(config, buckets)
    @config = config
    @buckets = buckets
    @estimator = CostEstimator.new(config)
  end

  def call(request, response)
    route(request, response)
  end

  private

  def route(request, response)
    cors_headers(response)

    return options(response) if request.request_method == "OPTIONS"
    return health(response, request) if request.path == "/health"
    return models(response) if request.request_method == "GET" && request.path == "/v1/models"
    return unauthorized(response) unless authorized?(request)

    if completion_request?(request)
      handle_completion(request, response)
    else
      proxy_to_upstream(request, response)
    end
  rescue JSON::ParserError
    json_response(response, 400, error_body("invalid_request_error", "Request body must be valid JSON"))
  rescue StandardError => error
    warn "#{error.class}: #{error.message}"
    json_response(response, 502, error_body("upstream_error", error.message))
  end

  def options(response)
    response.status = 204
  end

  def health(response, request)
    identity = identity_for(request)
    bucket = @buckets.fetch(identity).state

    json_response(
      response,
      200,
      {
        ok: true,
        model: @config.base_model,
        upstream_base_url: @config.upstream_base_url,
        quota: public_bucket_state(bucket)
      }
    )
  end

  def models(response)
    model = @config.base_model || "upstream-model"

    json_response(
      response,
      200,
      {
        object: "list",
        data: [
          {
            id: model,
            object: "model",
            created: Time.now.to_i,
            owned_by: "llm-proxy"
          }
        ]
      }
    )
  end

  def handle_completion(request, response)
    payload = parse_json_body(request)
    requested_model = payload["model"] || @config.base_model || "proxy-model"
    stream = payload["stream"] == true

    payload["model"] = @config.base_model if @config.base_model
    cost = @estimator.cost(payload)
    bucket = @buckets.fetch(identity_for(request))
    decision = bucket.consume(cost)
    quota_headers(response, decision)

    unless decision[:allowed]
      return limit_stream_response(response, request.path, requested_model, decision[:wait_seconds]) if stream

      return limit_json_response(response, request.path, requested_model, decision[:wait_seconds])
    end

    proxy_to_upstream(request, response, JSON.generate(payload))
  end

  def proxy_to_upstream(request, response, body_override = nil)
    unless @config.upstream_base_url
      return json_response(
        response,
        502,
        error_body("configuration_error", "Set UPSTREAM_BASE_URL or BASE_API_URL before proxying requests")
      )
    end

    uri = upstream_uri(request)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = @config.open_timeout
    http.read_timeout = @config.read_timeout

    upstream_request = build_upstream_request(request, uri, body_override)
    upstream_response = http.request(upstream_request)
    response.status = upstream_response.code.to_i
    copy_response_headers(upstream_response, response)
    response.body = upstream_response.body
  end

  def parse_json_body(request)
    body = request.body.to_s
    return {} if body.empty?

    parsed = JSON.parse(body)
    return parsed if parsed.is_a?(Hash)

    raise JSON::ParserError, "JSON body must be an object"
  end

  def build_upstream_request(request, uri, body_override)
    request_class = HTTP_METHODS.fetch(request.request_method) do
      raise "Unsupported HTTP method: #{request.request_method}"
    end

    upstream_request = request_class.new(uri)
    copy_request_headers(request, upstream_request)
    upstream_request["Authorization"] = "Bearer #{@config.upstream_api_key}" if @config.upstream_api_key
    upstream_request["Content-Type"] ||= "application/json"
    upstream_request.body = body_override || request.body if request_body_method?(request.request_method)
    upstream_request
  end

  def upstream_uri(request)
    base = URI.parse(@config.upstream_base_url)
    suffix = if request.path.start_with?("/v1/")
               request.path.sub(%r{\A/v1}, "")
             elsif request.path == "/v1"
               ""
             else
               request.path
             end

    base_path = base.path.to_s
    base_path = "" if base_path == "/"
    base.path = "#{base_path.chomp("/")}#{suffix}"
    base.path = "/" if base.path.empty?
    base.query = request.query_string
    base
  end

  def copy_request_headers(request, upstream_request)
    request.header.each do |name, values|
      next if HOP_BY_HOP_HEADERS.include?(name.downcase)

      upstream_request[name] = values.join(", ")
    end
  end

  def copy_response_headers(upstream_response, response)
    upstream_response.each_header do |name, value|
      next if HOP_BY_HOP_HEADERS.include?(name.downcase)

      response[name] = value
    end
  end

  def completion_request?(request)
    request.request_method == "POST" && COMPLETION_PATHS.include?(request.path)
  end

  def request_body_method?(method)
    %w[POST PUT PATCH DELETE].include?(method)
  end

  def authorized?(request)
    return true unless @config.authenticated_keys?

    @config.proxy_api_keys.include?(bearer_token(request))
  end

  def unauthorized(response)
    json_response(response, 401, error_body("authentication_error", "Missing or invalid proxy API key"))
  end

  def identity_for(request)
    bearer_token(request) || remote_ip(request) || "anonymous"
  end

  def bearer_token(request)
    request["authorization"].to_s.sub(/\ABearer\s+/i, "").strip.then { |value| value.empty? ? nil : value }
  end

  def remote_ip(request)
    request.remote_ip
  end

  def limit_json_response(response, path, model, wait_seconds)
    if path == "/v1/completions"
      return json_response(response, 200, completion_limit_body(model, wait_seconds))
    end

    json_response(response, 200, chat_limit_body(model, wait_seconds))
  end

  def limit_stream_response(response, path, model, wait_seconds)
    response.status = 200
    response["Content-Type"] = "text/event-stream"
    response["Cache-Control"] = "no-cache"

    response.body = if path == "/v1/completions"
                      stream_event(completion_limit_chunk(model, wait_seconds))
                    else
                      stream_event(chat_limit_chunk(model, wait_seconds))
                    end
  end

  def chat_limit_body(model, wait_seconds)
    {
      id: "chatcmpl-limit-#{SecureRandom.hex(6)}",
      object: "chat.completion",
      created: Time.now.to_i,
      model: model,
      choices: [
        {
          index: 0,
          message: {
            role: "assistant",
            content: limit_message(wait_seconds)
          },
          finish_reason: "stop"
        }
      ],
      usage: {
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      }
    }
  end

  def completion_limit_body(model, wait_seconds)
    {
      id: "cmpl-limit-#{SecureRandom.hex(6)}",
      object: "text_completion",
      created: Time.now.to_i,
      model: model,
      choices: [
        {
          index: 0,
          text: limit_message(wait_seconds),
          finish_reason: "stop"
        }
      ],
      usage: {
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      }
    }
  end

  def chat_limit_chunk(model, wait_seconds)
    {
      id: "chatcmpl-limit-#{SecureRandom.hex(6)}",
      object: "chat.completion.chunk",
      created: Time.now.to_i,
      model: model,
      choices: [
        {
          index: 0,
          delta: {
            role: "assistant",
            content: limit_message(wait_seconds)
          },
          finish_reason: "stop"
        }
      ]
    }
  end

  def completion_limit_chunk(model, wait_seconds)
    {
      id: "cmpl-limit-#{SecureRandom.hex(6)}",
      object: "completion.chunk",
      created: Time.now.to_i,
      model: model,
      choices: [
        {
          index: 0,
          text: limit_message(wait_seconds),
          finish_reason: "stop"
        }
      ]
    }
  end

  def limit_message(wait_seconds)
    "limit reached, wait #{format_wait(wait_seconds)}"
  end

  def format_wait(seconds)
    minutes = (seconds / 60.0).ceil
    return "#{seconds}s" if minutes < 1
    return "1 min" if minutes == 1

    "#{minutes} min"
  end

  def stream_event(payload)
    "data: #{JSON.generate(payload)}\n\n" \
      "data: [DONE]\n\n"
  end

  def json_response(response, status, body)
    response.status = status
    response["Content-Type"] = "application/json"
    response.body = JSON.pretty_generate(body)
  end

  def error_body(type, message)
    {
      error: {
        message: message,
        type: type,
        param: nil,
        code: nil
      }
    }
  end

  def cors_headers(response)
    response["Access-Control-Allow-Origin"] = "*"
    response["Access-Control-Allow-Headers"] = "authorization, content-type"
    response["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  end

  def quota_headers(response, bucket_state)
    response["X-RateLimit-Limit"] = bucket_state[:limit].to_s
    response["X-RateLimit-Remaining"] = bucket_state[:remaining].to_s
    response["X-RateLimit-Refill-Tokens"] = bucket_state[:refill_tokens].to_s
    response["X-RateLimit-Refill-Seconds"] = bucket_state[:refill_interval_seconds].to_s
    response["X-RateLimit-Reset-Seconds"] = bucket_state[:wait_seconds].to_s
  end

  def public_bucket_state(bucket_state)
    {
      limit: bucket_state[:limit],
      remaining: bucket_state[:remaining],
      refill_tokens: bucket_state[:refill_tokens],
      refill_interval_seconds: bucket_state[:refill_interval_seconds],
      wait_seconds: bucket_state[:wait_seconds]
    }
  end
end

if $PROGRAM_NAME == __FILE__
  config = Config.new(ENV)
  buckets = BucketStore.new(config)
  app = ProxyApp.new(config, buckets)

  server = HttpServer.new(host: config.host, port: config.port, app: app)

  trap("INT") { server.shutdown }
  trap("TERM") { server.shutdown }

  warn "llm proxy listening on #{config.host}:#{server.port}"
  warn "upstream: #{config.upstream_base_url || "(not configured)"}"
  warn "model: #{config.base_model || "(unchanged)"}"
  warn "bucket: max=#{config.max_tokens}, refill=#{config.refill_tokens}/#{config.refill_interval_seconds}s"

  server.start
end
