module Events
  class Ingest < ApplicationOperation
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
      Event.transaction do
        endpoints = lock_eligible_endpoints(project, attributes[:event_type])
        reject_when_full!(endpoints)
        event = project.events.create!(
          event_type: attributes[:event_type],
          payload: attributes[:payload],
          idempotency_key: attributes[:idempotency_key]
        )
        [event, Events::FanOut.call(event: event, endpoints: endpoints), true]
      end
    rescue ActiveRecord::RecordNotUnique
      [existing_event!(project, attributes), [], false]
    rescue EndpointQueueFull => e
      record_rejection(project, attributes, e.endpoint)
      raise ApiError::QueueCapacityExceededError
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

    def record_rejection(project, attributes, endpoint)
      IngestRejection.create!(
        project: project,
        endpoint: endpoint,
        reason: IngestRejection::QUEUE_CAPACITY_EXCEEDED,
        event_type: attributes[:event_type],
        idempotency_key: attributes[:idempotency_key],
        payload: rejection_payload(attributes[:payload])
      )
    end

    def rejection_payload(payload)
      payload.is_a?(Hash) ? payload : {}
    end

    def existing_event!(project, attributes)
      event = project.events.find_by!(idempotency_key: attributes[:idempotency_key])
      expected_fingerprint = Event.fingerprint_for(event_type: attributes[:event_type], payload: attributes[:payload])

      unless event.idempotency_fingerprint == expected_fingerprint
        raise ApiError::UnprocessableEntityError.new(message: 'Idempotency key already used with a different request')
      end

      event
    end
  end
end
