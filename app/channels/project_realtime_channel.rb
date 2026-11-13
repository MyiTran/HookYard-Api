class ProjectRealtimeChannel < ApplicationCable::Channel
  STREAM_PREFIX = 'projects'

  EVENT_MESSAGE_CHANGED = 'message.changed'
  EVENT_ENDPOINT_CHANGED = 'endpoint.changed'
  EVENT_REPLAY_CHANGED = 'replay.changed'

  SAFE_PAYLOAD_KEYS = %w[
    type project_id endpoint_id message_id replay_run_id replay_item_id
    status delivery_state circuit_state occurred_at
  ].freeze

  def subscribed
    project = ProjectPolicy::Scope.new(current_user, Project).resolve.find_by(id: params[:project_id])
    return reject unless project

    stream_from self.class.stream_name(project.id)
  end

  class << self
    def stream_name(project_id)
      "#{STREAM_PREFIX}:#{project_id}"
    end

    def broadcast(project_id, payload)
      ActionCable.server.broadcast(stream_name(project_id), sanitize_payload(payload))
    end

    def message_changed(message)
      broadcast(
        message.endpoint.project_id,
        type: EVENT_MESSAGE_CHANGED,
        project_id: message.endpoint.project_id,
        endpoint_id: message.endpoint_id,
        message_id: message.id,
        status: message.status,
        delivery_state: message.delivery_state,
        occurred_at: Time.current.iso8601
      )
    end

    def endpoint_messages_changed(project_id, endpoint_id)
      broadcast(
        project_id,
        type: EVENT_MESSAGE_CHANGED,
        project_id: project_id,
        endpoint_id: endpoint_id,
        occurred_at: Time.current.iso8601
      )
    end

    def endpoint_circuit_changed(endpoint)
      broadcast(
        endpoint.project_id,
        type: EVENT_ENDPOINT_CHANGED,
        project_id: endpoint.project_id,
        endpoint_id: endpoint.id,
        circuit_state: endpoint.circuit_state,
        occurred_at: Time.current.iso8601
      )
    end

    def replay_changed(project_id:, replay_run_id:, replay_item_id: nil, endpoint_id: nil, message_id: nil)
      broadcast(
        project_id,
        type: EVENT_REPLAY_CHANGED,
        project_id: project_id,
        replay_run_id: replay_run_id,
        replay_item_id: replay_item_id,
        endpoint_id: endpoint_id,
        message_id: message_id,
        occurred_at: Time.current.iso8601
      )
    end

    private

    def sanitize_payload(payload)
      payload.stringify_keys.slice(*SAFE_PAYLOAD_KEYS).compact
    end
  end
end
