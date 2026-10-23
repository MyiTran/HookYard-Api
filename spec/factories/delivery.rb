FactoryBot.define do
  factory :event do
    project
    event_type { 'order.created' }
    payload { { 'order_id' => SecureRandom.uuid } }
    sequence(:idempotency_key) { |index| "idempotency-#{index}" }
  end

  factory :message do
    transient do
      project { association(:project) }
    end

    event { association(:event, project: project) }
    endpoint { association(:endpoint, project: project) }
    status { :pending }
  end

  factory :delivery_attempt do
    message
    attempt_number { (message.delivery_attempts.maximum(:attempt_number) || 0) + 1 }
    request_id { "req_#{SecureRandom.uuid}" }
    webhook_id { message.webhook_id }
    signing_secret_version { message.endpoint.signing_secret_version }
    signed_at { Time.current }
    request_url { message.endpoint.url }
    http_method { 'POST' }
    request_headers { { 'content-type' => 'application/json' } }
    request_body { '{}' }
  end
end
