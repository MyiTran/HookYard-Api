module Webhooks
  # Strips credentials from delivery evidence before it is serialized to API
  # clients. Persisted evidence keeps the bytes that were actually sent and
  # received so delivery behavior and audits stay faithful.
  module EvidenceSanitizer
    REDACTED_VALUE = '[REDACTED]'

    SENSITIVE_HEADER_PATTERN = /authorization|cookie|signature|secret|token|api[-_]?key/i
    INTERNAL_HEADER_NAMES = %w[server-timing].freeze

    SENSITIVE_PARAM_NAMES = %w[
      token access_token access-token api_key api-key apikey key secret signature authorization password auth
    ].freeze

    SENSITIVE_PARAM_PATTERN = /(?<=[?&])(?:#{Regexp.union(SENSITIVE_PARAM_NAMES)})=[^&#]*/i

    module_function

    def sanitize_headers(headers)
      return headers if headers.nil?

      headers.to_h.each_with_object({}) do |(name, value), sanitized|
        sanitized[name.to_s] = value unless redacted_header?(name)
      end
    end

    def sanitize_url(url)
      return url if url.blank?

      url.to_s.gsub(SENSITIVE_PARAM_PATTERN) { |match| "#{match.split('=', 2).first}=#{REDACTED_VALUE}" }
    end

    def redacted_header?(name)
      normalized = name.to_s.downcase

      INTERNAL_HEADER_NAMES.include?(normalized) || normalized.match?(SENSITIVE_HEADER_PATTERN)
    end
  end
end
