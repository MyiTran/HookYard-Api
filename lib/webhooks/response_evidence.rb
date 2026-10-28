module Webhooks
  # Normalizes receiver-controlled data before it becomes durable evidence:
  # bounds response bodies, scrubs invalid UTF-8 and drops credential headers.
  module ResponseEvidence
    RESPONSE_BODY_MAX_BYTES = 4096
    ERROR_MESSAGE_MAX_BYTES = 1024
    SENSITIVE_HEADERS = %w[set-cookie cookie authorization proxy-authenticate www-authenticate].freeze

    module_function

    def truncate_response_body(body)
      return nil if body.nil?

      normalize_external_text(body.to_s.byteslice(0, RESPONSE_BODY_MAX_BYTES))
    end

    def truncate_error_message(message)
      return nil if message.nil?

      normalize_external_text(message.to_s.byteslice(0, ERROR_MESSAGE_MAX_BYTES))
    end

    def filter_headers(headers)
      headers.to_h.stringify_keys.except(*SENSITIVE_HEADERS)
             .transform_values { |value| normalize_header_value(value) }
    end

    def normalize_external_text(value)
      value.to_s.force_encoding(Encoding::UTF_8).scrub
    end

    def normalize_header_value(value)
      value.is_a?(Array) ? value.map { |entry| normalize_external_text(entry) } : normalize_external_text(value)
    end
  end
end
