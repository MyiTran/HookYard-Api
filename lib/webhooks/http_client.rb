require 'net/http'
require 'uri'

module Webhooks
  class HttpClient
    Result = Struct.new(:status, :headers, :body, :duration_ms, :error, :error_type, keyword_init: true) do
      def error?
        error.present?
      end
    end

    def post(url:, headers:, body:, timeout: Constants::WEBHOOK_HTTP_TIMEOUT_SECONDS)
      started_at = monotonic_time
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri.request_uri)
      headers.each { |key, value| request[key.to_s] = value.to_s }
      request.body = body

      response = Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == 'https',
        open_timeout: timeout,
        read_timeout: timeout
      ) { |http| http.request(request) }

      Result.new(
        status: response.code.to_i,
        headers: response.to_hash,
        body: response.body,
        duration_ms: elapsed_ms(started_at)
      )
    rescue StandardError => e
      Result.new(error: e.message, error_type: e.class.name, duration_ms: elapsed_ms(started_at))
    end

    private

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      return 0 if started_at.nil?

      ((monotonic_time - started_at) * 1000).round
    end
  end
end
