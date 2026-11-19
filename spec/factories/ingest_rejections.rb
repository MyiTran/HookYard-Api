FactoryBot.define do
  factory :ingest_rejection do
    project
    event_type { 'order.created' }
    reason { IngestRejection::QUEUE_CAPACITY_EXCEEDED }
    idempotency_key_digest { IngestRejection.digest_idempotency_key(SecureRandom.uuid) }
    payload { { 'payload_keys' => %w[order_id], 'payload_bytes' => 42 } }
  end
end
