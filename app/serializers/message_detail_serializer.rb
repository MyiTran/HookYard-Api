class MessageDetailSerializer < ApplicationSerializer
  identifier :id

  fields :webhook_id, :status, :created_at, :updated_at
  fields :attempt_count, :next_retry_at, :terminal_at

  field :max_attempts do
    Webhooks::DeliveryPolicy::MAX_ATTEMPTS
  end

  field :retryable do |message|
    message.retryable?
  end

  field :event do |message|
    {
      id: message.event.id,
      event_type: message.event.event_type,
      payload: message.event.payload,
      created_at: message.event.created_at
    }
  end

  field :endpoint do |message|
    {
      id: message.endpoint.id,
      name: message.endpoint.name,
      url: message.endpoint.url,
      project: {
        id: message.endpoint.project.id,
        name: message.endpoint.project.name
      }
    }
  end

  field :attempts do |message|
    message.delivery_attempts.map { |attempt| DeliveryAttemptSerializer.render_as_hash(attempt) }
  end
end
