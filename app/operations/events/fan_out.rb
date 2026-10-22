module Events
  class FanOut < ApplicationOperation
    def call(event:)
      endpoint_ids = eligible_endpoints(event).pluck(:id)
      return [] if endpoint_ids.empty?

      rows = endpoint_ids.map { |endpoint_id| { event_id: event.id, endpoint_id: endpoint_id, status: Message::PENDING_STATUS } }

      Message.insert_all(
        rows,
        unique_by: %i[event_id endpoint_id],
        returning: %i[id],
        record_timestamps: true
      ).map { |row| row['id'] }
    end

    private

    def eligible_endpoints(event)
      event.project.endpoints
           .not_archived
           .where(active: true)
           .where(
             '? = ANY(endpoints.event_types) OR ? = ANY(endpoints.event_types)',
             Endpoint::WILDCARD_EVENT_TYPE,
             event.event_type
           )
    end
  end
end
