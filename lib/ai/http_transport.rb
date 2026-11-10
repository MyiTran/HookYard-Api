require 'net/http'
require 'uri'

module Ai
  # Narrow HTTPS client for AI providers. Separate from Webhooks::HttpClient on
  # purpose: provider traffic must not be resolved/pinned through the webhook
  # destination policy, which guards customer-controlled destinations only.
  class HttpTransport
    Result = Struct.new(:status, :body, keyword_init: true)

    # Raised while streaming, so an oversized provider answer is never buffered in
    # full: the caller treats it as a failed AI answer and records the fallback.
    class ResponseTooLargeError < StandardError; end

    MAX_RESPONSE_BYTES = 32_768

    def post_json(url:, headers:, body:, open_timeout:, read_timeout:)
      uri = URI.parse(url)
      raise ArgumentError, 'AI provider requests must use https' unless uri.scheme == 'https'

      status = nil
      payload = nil

      build_http(uri, open_timeout, read_timeout).request(build_request(uri, headers, body)) do |response|
        status = response.code.to_i
        payload = read_bounded_body(response)
      end

      Result.new(status: status, body: payload.force_encoding(Encoding::UTF_8))
    end

    private

    def read_bounded_body(response)
      body = String.new(capacity: MAX_RESPONSE_BYTES, encoding: Encoding::BINARY)

      response.read_body do |chunk|
        body << chunk.to_s.b
        raise ResponseTooLargeError, 'AI provider response exceeded the read limit' if body.bytesize > MAX_RESPONSE_BYTES
      end

      body
    end

    def build_http(uri, open_timeout, read_timeout)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = open_timeout
      http.read_timeout = read_timeout

      http
    end

    def build_request(uri, headers, body)
      request = Net::HTTP::Post.new(uri.request_uri)
      headers.merge('content-type' => 'application/json').each { |name, value| request[name.to_s] = value.to_s }
      request.body = body

      request
    end
  end
end
