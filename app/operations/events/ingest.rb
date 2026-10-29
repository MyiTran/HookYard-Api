module Events
  class Ingest < ApplicationOperation
    REJECTION_PAYLOAD_KEY_LIMIT = 20
    REJECTION_PAYLOAD_KEY_MAX_LENGTH = 64

    Result = Struct.new(:event, :created, :message_ids, keyword_init: true) do
      def messages_count
        message_ids.size
      end
    end

    class EndpointQueueFull < StandardError
      attr_reader :endpoint

      def initialize(endpoint)
        @endpoint = endpoint
        super('endpoint queue capacity exceeded')
      end
    end

    def call(project:, attributes:)
      attributes = attributes.to_h.symbolize_keys
      event, message_ids, created = accept(project, attributes)
      Messages::EnqueueDelivery.call(message_ids: deliverable_message_ids(event))

      Result.new(event: event, created: created, message_ids: message_ids)
    end

    private

    def deliverable_message_ids(event)
      event.messages.pending.not_held.pluck(:id)
    end

    def accept(project, attributes)
      duplicate = project.events.find_by(idempotency_key: attributes[:idempotency_key])
      return [validate_duplicate!(duplicate, attributes), [], false] if duplicate

      Event.transaction do
        endpoints = lock_eligible_endpoints(project, attributes[:event_type])
        reject_when_full!(endpoints)
        reserve_delivery_quota!(project, endpoints.size)
        event = project.events.create!(
          event_type: attributes[:event_type],
          payload: attributes[:payload],
          idempotency_key: attributes[:idempotency_key]
        )
        [event, Events::FanOut.call(event: event, endpoints: endpoints), true]
      end
    rescue ActiveRecord::RecordNotUnique
      event = project.events.find_by!(idempotency_key: attributes[:idempotency_key])
      [validate_duplicate!(event, attributes), [], false]
    rescue EndpointQueueFull => e
      record_rejection(project, attributes, reason: IngestRejection::QUEUE_CAPACITY_EXCEEDED, endpoint: e.endpoint)
      raise ApiError::QueueCapacityExceededError
    rescue ApiError::PlanLimitExceededError
      record_rejection(project, attributes, reason: IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED)
      raise
    end

    def lock_eligible_endpoints(project, event_type)
      endpoint_ids = Events::FanOut.eligible_scope(project, event_type).order(:id).pluck(:id)
      return [] if endpoint_ids.empty?

      Endpoint.where(id: endpoint_ids).order(:id).lock.to_a
    end

    def reject_when_full!(endpoints)
      full_endpoint = endpoints.find { |endpoint| endpoint.queue_full? }
      raise EndpointQueueFull.new(full_endpoint) if full_endpoint
    end

    def reserve_delivery_quota!(project, deliveries)
      account = project.billing_owner
      limit = Plans::Entitlements.monthly_delivery_limit(account)
      return if UserUsagePeriod.reserve_deliveries(user: account, quantity: deliveries, limit: limit)

      raise ApiError::PlanLimitExceededError.new(
        message: "The #{account.plan} plan allows at most #{limit} deliveries per month",
        field: 'monthly_delivery_limit',
        used: UserUsagePeriod.used_deliveries(user: account),
        limit: limit,
        period_ends: UserUsagePeriod.period_ends_at
      )
    end

    def record_rejection(project, attributes, reason:, endpoint: nil)
      IngestRejection.create!(
        project: project,
        endpoint: endpoint,
        reason: reason,
        event_type: attributes[:event_type],
        idempotency_key_digest: IngestRejection.digest_idempotency_key(attributes[:idempotency_key]),
        payload: rejection_payload(attributes[:payload])
      )
    end

    def rejection_payload(payload)
      return {} if payload.nil?

      {
        'payload_keys' => rejection_payload_keys(payload),
        'payload_bytes' => payload.to_json.bytesize
      }
    end

    def rejection_payload_keys(payload)
      return [] unless payload.is_a?(Hash)

      payload.keys
             .map { |key| key.to_s.first(REJECTION_PAYLOAD_KEY_MAX_LENGTH) }
             .sort
             .first(REJECTION_PAYLOAD_KEY_LIMIT)
    end

    def validate_duplicate!(event, attributes)
      expected_fingerprint = Event.fingerprint_for(event_type: attributes[:event_type], payload: attributes[:payload])

      unless event.idempotency_fingerprint == expected_fingerprint
        raise ApiError::UnprocessableEntityError.new(message: 'Idempotency key already used with a different request')
      end

      event
    end
  end
end
