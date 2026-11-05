FactoryBot.define do
  factory :circuit_probe do
    endpoint
    request_id { "probe_#{SecureRandom.uuid}" }
    webhook_id { "probe_#{SecureRandom.uuid}" }
    signing_secret_version { endpoint.signing_secret_version }
    started_at { Time.current }
    request_url { endpoint.url }
    request_body { { id: webhook_id, type: 'endpoint.test' }.to_json }
    status { :pending }
  end
end
