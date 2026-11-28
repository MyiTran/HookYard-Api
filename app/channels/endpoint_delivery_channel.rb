class EndpointDeliveryChannel < ApplicationCable::Channel
  def self.broadcast_message(message)
    message = message.reload
    attempt = message.delivery_attempts.order(created_at: :desc, attempt_number: :desc).first

    broadcast_to(message.endpoint, payload_for(message, attempt))
  rescue StandardError => e
    Rails.logger.warn("endpoint delivery broadcast failed: #{e.class}")
    nil
  end

  def subscribed
    endpoint = Endpoint.find_by(id: params[:endpoint_id])
    reject unless endpoint && (current_user.admin? || EndpointPolicy.new(current_user, endpoint).show?)
    stream_for endpoint
  end

  class << self
    private

    def payload_for(message, attempt)
      {
        type: 'delivery.updated',
        endpoint_id: message.endpoint_id,
        message_id: message.id,
        event_type: message.event.event_type,
        status: message.held? ? 'held' : message.status,
        attempt_count: message.attempt_count,
        latest_attempt_status: attempt&.status,
        response_status: attempt&.response_status,
        error_type: attempt&.error_type,
        duration_ms: attempt&.duration_ms,
        occurred_at: message.updated_at.iso8601
      }
    end
  end
end
