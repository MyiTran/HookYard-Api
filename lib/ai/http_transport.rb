require 'net/http'
require 'uri'

module Ai
  # Narrow HTTPS client for AI providers. Separate from Webhooks::HttpClient on
  # purpose: provider traffic must not be resolved/pinned through the webhook
  # destination policy, which guards customer-controlled destinations only.
  class HttpTransport
    Result = Struct.new(:status, :body, keyword_init: true)

    MAX_RESPONSE_BYTES = 32_768

    def post_json(url:, headers:, body:, open_timeout:, read_timeout:)
      uri = URI.parse(url)
      raise ArgumentError, 'AI provider requests must use https' unless uri.scheme == 'https'

      response = build_http(uri, open_timeout, read_timeout).request(build_request(uri, headers, body))

      Result.new(status: response.code.to_i, body: response.body.to_s.byteslice(0, MAX_RESPONSE_BYTES))
    end

    private

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
