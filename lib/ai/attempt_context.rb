module Ai
  # Builds the minimal, sanitized and bounded picture of one delivery attempt for
  # the diagnosis prompt. Request evidence is deliberately left out: it does not
  # help classify the receiver failure and is the part most likely to carry
  # customer secrets.
  module AttemptContext
    ATTEMPT_LIMIT_DEFAULT = 10
    ATTEMPT_LIMIT_MAX = 20
    HEADER_LIMIT = 10
    HEADER_VALUE_MAX_BYTES = 96
    BODY_EXCERPT_MAX_BYTES = 512

    module_function

    def attempt_limit
      configured = ENV.fetch('AI_DIAGNOSIS_ATTEMPT_LIMIT', nil).to_i

      configured.between?(1, ATTEMPT_LIMIT_MAX) ? configured : ATTEMPT_LIMIT_DEFAULT
    end

    def for(attempt)
      {
        response_status: attempt.response_status,
        response_headers: headers(attempt.response_headers),
        response_body_excerpt: body_excerpt(attempt.response_body),
        duration_ms: attempt.duration_ms,
        failure_category: attempt.failure_category,
        occurred_at: attempt.created_at.utc.iso8601
      }
    end

    def headers(raw_headers)
      sanitized = Webhooks::EvidenceSanitizer.sanitize_headers(raw_headers || {})

      sanitized.first(HEADER_LIMIT).to_h do |name, value|
        [name.to_s, bounded(Array(value).map(&:to_s).join(', '), HEADER_VALUE_MAX_BYTES)]
      end
    end

    def body_excerpt(body)
      return nil if body.blank?

      bounded(Webhooks::EvidenceSanitizer.sanitize_body(body).to_s, BODY_EXCERPT_MAX_BYTES)
    end

    def bounded(value, max_bytes)
      Webhooks::ResponseEvidence.normalize_external_text(value.to_s.byteslice(0, max_bytes))
    end
  end
end
