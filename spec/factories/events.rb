FactoryBot.define do
  factory :event do
    project
    event_type { 'order.created' }
    payload { { 'order_id' => SecureRandom.uuid } }
    sequence(:idempotency_key) { |number| "event-#{number}" }
  end
end
