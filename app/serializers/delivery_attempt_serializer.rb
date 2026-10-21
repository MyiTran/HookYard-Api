class DeliveryAttemptSerializer < ApplicationSerializer
  REDACTED_REQUEST_HEADERS = %w[webhook-signature].freeze

  identifier :id

  fields :attempt_number, :request_id, :webhook_id, :signing_secret_version, :signed_at, :created_at,
         :request_url, :http_method, :request_body, :response_status, :response_headers, :response_body,
         :duration_ms, :error_type, :error_message

  field :request_headers do |attempt|
    attempt.request_headers.to_h.except(*REDACTED_REQUEST_HEADERS)
  end

  field :status do |attempt|
    attempt.succeeded? ? 'succeeded' : 'failed'
  end
end
