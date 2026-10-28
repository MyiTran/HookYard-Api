module Events
  class FanOut < ApplicationOperation
    def self.eligible_scope(project, event_type)
      project.endpoints
             .not_archived
             .where(active: true)
             .where(
               '? = ANY(endpoints.event_types) OR ? = ANY(endpoints.event_types)',
               Endpoint::WILDCARD_EVENT_TYPE,
               event_type
             )
    end

    def call(event:, endpoints: nil)
      endpoints ||= self.class.eligible_scope(event.project, event.event_type).order(:id).to_a
      return [] if endpoints.empty?

      created = Message.insert_all(
        rows(event, endpoints),
        unique_by: %i[event_id endpoint_id],
        returning: %i[id endpoint_id held_at],
        record_timestamps: true
      )

      increment_queue_counters(created)

      created.map { |row| row['id'] }
    end

    private

    def rows(event, endpoints)
      queued_at = Time.current

      endpoints.map do |endpoint|
        {
          event_id: event.id,
          endpoint_id: endpoint.id,
          status: Message::PENDING_STATUS,
          queued_at: queued_at,
          held_at: endpoint.enabled? ? nil : queued_at,
          hold_reason: endpoint.circuit_hold_reason
        }
      end
    end

    def increment_queue_counters(created)
      created.group_by { |row| row['endpoint_id'] }.each do |endpoint_id, rows|
        Endpoint.where(id: endpoint_id).update_all(
          ['queued_message_count = queued_message_count + ?', rows.size]
        )
      end
    end
  end
end
