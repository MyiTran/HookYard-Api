FactoryBot.define do
  factory :delivery_attempt do
    message
    sequence(:attempt_number)
    request_id { "req_#{SecureRandom.uuid}" }
    webhook_id { "msg_#{SecureRandom.uuid}" }
    signing_secret_version { 1 }
    signed_at { Time.current }
    request_url { 'https://example.com/hooks' }
    http_method { 'POST' }
    request_headers { { 'content-type' => 'application/json' } }
    request_body { '{"type":"order.created"}' }
  end
end
