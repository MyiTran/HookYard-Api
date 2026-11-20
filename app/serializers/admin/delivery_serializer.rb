module Admin
  class DeliverySerializer < ApplicationSerializer
    identifier :id

    fields :status, :attempt_count, :terminal_at, :next_retry_at, :last_attempt_at, :last_response_status,
           :last_duration_ms, :created_at, :updated_at

    field(:webhook_id) { |message| message.webhook_id }

    field(:delivery_state) { |message| message.delivery_state }

    field(:failure_category) { |message| message.failure_category }

    field(:hold) { |message| message.hold_summary }

    field(:event) do |message|
      { id: message.event_id, event_type: message.event.event_type, created_at: message.event.created_at }
    end

    field(:endpoint) do |message|
      { id: message.endpoint_id, name: message.endpoint.name }
    end

    field(:project) do |message|
      { id: message.endpoint.project_id, name: message.endpoint.project.name }
    end
  end
end
