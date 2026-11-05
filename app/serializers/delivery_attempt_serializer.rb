class DeliveryAttemptSerializer < ApplicationSerializer
  identifier :id

  fields :status, :attempt_number, :request_id, :webhook_id, :signing_secret_version, :signed_at, :created_at,
         :http_method, :response_status, :duration_ms, :error_type, :error_message, :bodies_purged_at

  field :failure_category do |attempt|
    attempt.failure_category
  end

  field :request_body do |attempt|
    Webhooks::EvidenceSanitizer.sanitize_body(attempt.request_body)
  end

  field :response_body do |attempt|
    Webhooks::EvidenceSanitizer.sanitize_body(attempt.response_body)
  end

  field :request_url do |attempt|
    Webhooks::EvidenceSanitizer.sanitize_url(attempt.request_url)
  end

  field :request_headers do |attempt|
    Webhooks::EvidenceSanitizer.sanitize_headers(attempt.request_headers)
  end

  field :response_headers do |attempt|
    Webhooks::EvidenceSanitizer.sanitize_headers(attempt.response_headers)
  end
end
