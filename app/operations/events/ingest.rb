module Events
  class Ingest < ApplicationOperation
    Result = Struct.new(:event, :created, :message_ids, keyword_init: true) do
      def messages_count
        message_ids.size
      end
    end

    def call(project:, attributes:)
      event, message_ids, created = accept(project, attributes.to_h.symbolize_keys)
      Messages::EnqueueDelivery.call(message_ids: delivery_message_ids(event, message_ids, created))

      Result.new(event: event, created: created, message_ids: message_ids)
    end

    private

    def delivery_message_ids(event, message_ids, created)
      created ? message_ids : event.messages.pending.pluck(:id)
    end

    def accept(project, attributes)
      Event.transaction do
        event = project.events.create!(
          event_type: attributes[:event_type],
          payload: attributes[:payload],
          idempotency_key: attributes[:idempotency_key]
        )
        [event, Events::FanOut.call(event: event), true]
      end
    rescue ActiveRecord::RecordNotUnique
      [existing_event!(project, attributes), [], false]
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
