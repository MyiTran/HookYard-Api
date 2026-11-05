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

    SENSITIVE_BODY_KEYS = %w[
      authorization cookie password secret token access_token api_key apikey signature auth
      refresh_token session_token id_token client_secret private_key access_key
      card_number cvv cvc
    ].freeze

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

    def sanitize_body(body)
      return body if body.nil?

      parsed = JSON.parse(body.to_s)
      return body unless parsed.is_a?(Hash) || parsed.is_a?(Array)

      JSON.pretty_generate(redact_json(parsed))
    rescue JSON::ParserError, EncodingError, ArgumentError
      body
    end

    def redact_json(value)
      case value
      when Hash then redact_hash(value)
      when Array then value.map { |entry| redact_json(entry) }
      else value
      end
    end

    def redact_hash(hash)
      hash.each_with_object({}) do |(key, value), sanitized|
        sanitized[key] = sensitive_body_key?(key) ? REDACTED_VALUE : redact_json(value)
      end
    end

    def sensitive_body_key?(key)
      SENSITIVE_BODY_KEYS.include?(normalize_key(key))
    end

    def normalize_key(key)
      key.to_s.downcase.tr('-', '_')
    end

    def redacted_header?(name)
      normalized = name.to_s.downcase

      INTERNAL_HEADER_NAMES.include?(normalized) || normalized.match?(SENSITIVE_HEADER_PATTERN)
    end
  end
end
