module Ai
  # Deterministic diagnosis used whenever the provider is unavailable or returns
  # output that fails validation. It never raises, so an AI outage can not break
  # the diagnosis endpoint.
  module FallbackDiagnosis
    AUTH_EXPIRED_STATUSES = [401, 403].freeze
    RECEIVER_SERVER_ERROR_STATUSES = (500..599)
    ENDPOINT_GONE_STATUS = 410

    ACTIONS = {
      Diagnosis::AUTH_EXPIRED => 'Check and refresh the endpoint authentication credentials, then retry delivery.',
      Diagnosis::HANDLER_TIMEOUT =>
        'Increase the receiver response time or investigate why the handler exceeds the delivery timeout.',
      Diagnosis::ENDPOINT_GONE => 'Update the endpoint URL to an active receiver, then retry delivery.',
      Diagnosis::RECEIVER_SERVER_ERROR =>
        'Inspect the receiver server logs, recover the endpoint, then retry delivery.',
      Diagnosis::UNKNOWN => 'Review the latest delivery attempt and receiver logs, then correct the endpoint before retrying.'
    }.freeze

    module_function

    def for(attempt)
      label = label_for(attempt)

      Diagnosis::Result.new(
        label: label,
        suggested_action: ACTIONS.fetch(label),
        source: Diagnosis::SOURCE_FALLBACK,
        model: nil
      )
    end

    def label_for(attempt)
      return Diagnosis::UNKNOWN if attempt.nil?
      return Diagnosis::AUTH_EXPIRED if AUTH_EXPIRED_STATUSES.include?(attempt.response_status)
      return Diagnosis::RECEIVER_SERVER_ERROR if RECEIVER_SERVER_ERROR_STATUSES.cover?(attempt.response_status)
      return Diagnosis::HANDLER_TIMEOUT if transport_timeout?(attempt)
      return Diagnosis::ENDPOINT_GONE if attempt.response_status == ENDPOINT_GONE_STATUS

      Diagnosis::UNKNOWN
    end

    def transport_timeout?(attempt)
      attempt.error_type.present? && attempt.failure_category == Webhooks::FailureCategory::TIMEOUT
    end
  end
end
