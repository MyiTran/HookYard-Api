module Ai
  # Deterministic diagnosis used whenever the provider is unavailable or returns
  # output that fails validation. It never raises, so an AI outage can not break
  # the diagnosis endpoint.
  module FallbackDiagnosis
    AUTH_EXPIRED_STATUSES = [401, 403].freeze
    ENDPOINT_GONE_STATUSES = [404, 410].freeze
    PAYLOAD_REJECTED_STATUSES = [400, 409, 415, 422].freeze
    TIMEOUT_STATUSES = [408, 504].freeze
    RATE_LIMITED_STATUS = 429
    TLS_ERROR_PATTERN = /ssl|tls/i

    ACTIONS = {
      Diagnosis::AUTH_EXPIRED => 'Check and refresh the endpoint authentication credentials, then retry delivery.',
      Diagnosis::HANDLER_TIMEOUT =>
        'Increase the receiver response time or investigate why the handler exceeds the delivery timeout.',
      Diagnosis::ENDPOINT_GONE => 'Update the endpoint URL to an active receiver, then retry delivery.',
      Diagnosis::PAYLOAD_REJECTED => 'Validate the webhook payload against the receiver contract, then retry delivery.',
      Diagnosis::RATE_LIMITED => 'Reduce the delivery rate or retry after the receiver rate limit resets.',
      Diagnosis::TLS_FAILURE => 'Check the receiver TLS certificate and supported TLS configuration, then retry delivery.',
      Diagnosis::UNKNOWN => 'Review the latest delivery attempt and receiver logs, then correct the endpoint before retrying.'
    }.freeze

    module_function

    def for(attempts)
      attempts = Array(attempts)
      label = dominant_label(attempts)

      Diagnosis::Result.new(
        label: label,
        suggested_action: ACTIONS.fetch(label),
        source: Diagnosis::SOURCE_FALLBACK,
        model: nil,
        analyzed_attempt_count: attempts.size
      )
    end

    def dominant_label(attempts)
      return Diagnosis::UNKNOWN if attempts.empty?

      counts = attempts.each_with_object(Hash.new(0)) { |attempt, counts| counts[label_for(attempt)] += 1 }
      max_count = counts.values.max
      tied_labels = counts.select { |_, count| count == max_count }.keys
      return tied_labels.first if tied_labels.one?

      # The operation passes attempts newest first, so the first tied label is the newest attempt's label.
      label_for(attempts.find { |attempt| tied_labels.include?(label_for(attempt)) })
    end

    def label_for(attempt)
      return Diagnosis::UNKNOWN if attempt.nil?
      return Diagnosis::AUTH_EXPIRED if AUTH_EXPIRED_STATUSES.include?(attempt.response_status)
      return Diagnosis::PAYLOAD_REJECTED if PAYLOAD_REJECTED_STATUSES.include?(attempt.response_status)
      return Diagnosis::ENDPOINT_GONE if ENDPOINT_GONE_STATUSES.include?(attempt.response_status)
      return Diagnosis::HANDLER_TIMEOUT if timeout?(attempt)
      return Diagnosis::RATE_LIMITED if attempt.response_status == RATE_LIMITED_STATUS
      return Diagnosis::TLS_FAILURE if tls_error?(attempt)

      Diagnosis::UNKNOWN
    end

    def timeout?(attempt)
      TIMEOUT_STATUSES.include?(attempt.response_status) ||
        (attempt.error_type.present? && attempt.failure_category == Webhooks::FailureCategory::TIMEOUT)
    end

    def tls_error?(attempt)
      attempt.error_type.to_s.match?(TLS_ERROR_PATTERN)
    end
  end
end
