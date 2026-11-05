class ReplayPreviewSerializer < ApplicationSerializer
  fields :requested_count, :eligible_count, :blocked_count, :max_items_per_run, :over_limit

  field :sample do |preview|
    preview.sample.map do |message|
      {
        message_id: message.id,
        event_type: message.event.event_type,
        endpoint: { id: message.endpoint.id, name: message.endpoint.name },
        terminal_at: message.terminal_at,
        failure_category: message.failure_category
      }
    end
  end
end
