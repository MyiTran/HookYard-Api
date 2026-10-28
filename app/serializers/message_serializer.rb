class MessageSerializer < ApplicationSerializer
  identifier :id

  fields :webhook_id, :status, :event_id, :created_at, :updated_at
  fields :attempt_count, :next_retry_at, :terminal_at

  field :event_type do |message|
    message.event.event_type
  end

  field :max_attempts do
    Webhooks::DeliveryPolicy::MAX_ATTEMPTS
  end

  field :retryable do |message|
    message.retryable?
  end

  fields :last_attempt_at, :last_response_status, :last_duration_ms, :last_error_type

  view :with_context do
    field :project do |message|
      { id: message.endpoint.project.id, name: message.endpoint.project.name }
    end

    field :endpoint do |message|
      { id: message.endpoint.id, name: message.endpoint.name, url: message.endpoint.url }
    end
  end
end
