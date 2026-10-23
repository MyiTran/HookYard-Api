require 'net/http'
require 'uri'

module Webhooks
  # Sends outbound webhook POST requests through the resolver-pinned address.
  # Applies connection/read timeouts and bounds captured response bodies.
  # Returns transport failures as delivery results instead of raising to the job.
  class HttpClient
    class ResponseBodyLimitReached < StandardError; end

    Result = Struct.new(:status, :headers, :body, :duration_ms, :error, :error_type, keyword_init: true) do
      def error?
        error.present?
      end
    end

    def initialize(resolver: DestinationResolver.new)
      @resolver = resolver
    end

    def post(url:, headers:, body:, timeout: DeliveryPolicy::HTTP_TIMEOUT_SECONDS,
             body_limit: DeliveryAttempt::RESPONSE_BODY_MAX_BYTES)
      started_at = monotonic_time
      uri = URI.parse(url)
      response = perform(uri, resolver.resolve(uri), headers, body, timeout, body_limit)

      Result.new(
        status: response[:status],
        headers: response[:headers],
        body: response[:body],
        duration_ms: elapsed_ms(started_at)
      )
    rescue StandardError => e
      Result.new(error: e.message, error_type: e.class.name, duration_ms: elapsed_ms(started_at))
    end

    private

    attr_reader :resolver

    def perform(uri, address, headers, body, timeout, body_limit)
      http = build_http(uri, address, timeout)
      read_response(http, build_request(uri, headers, body), body_limit)
    end

    def build_http(uri, address, timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.ipaddr = address
      http.open_timeout = timeout
      http.read_timeout = timeout
      http
    end

    def build_request(uri, headers, body)
      request = Net::HTTP::Post.new(uri.request_uri)
      headers.each { |key, value| request[key.to_s] = value.to_s }
      request.body = body
      request
    end

    def read_response(http, request, body_limit)
      captured = { status: nil, headers: nil, body: String.new(encoding: Encoding::BINARY) }

      begin
        http.start do |connection|
          connection.request(request) do |response|
            captured[:status] = response.code.to_i
            captured[:headers] = response.to_hash
            response.read_body { |chunk| append_chunk(captured[:body], chunk, body_limit) }
          end
        end
      rescue ResponseBodyLimitReached
        nil
      end

      captured.merge(body: captured[:body].byteslice(0, body_limit).to_s)
    end

    def append_chunk(buffer, chunk, body_limit)
      buffer << chunk
      raise ResponseBodyLimitReached if buffer.bytesize > body_limit
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      return 0 if started_at.nil?

      ((monotonic_time - started_at) * 1000).round
    end
  end
end
