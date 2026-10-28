module Messages
  # The endpoint queue counter is a durable projection of the messages that own a
  # queue slot (queued_at). Rebuilding it from those rows keeps the circuit queue
  # contract honest when a message reached a terminal state through a path that
  # did not release its slot.
  class ReconcileQueue < ApplicationOperation
    def call(endpoint:)
      Message.transaction do
        endpoint.with_lock do
          endpoint.reload
          clear_terminal_slots(endpoint)
          set_queued_message_count(endpoint)
        end
      end

      endpoint.reload
    end

    private

    def clear_terminal_slots(endpoint)
      endpoint.messages.terminal.where.not(queued_at: nil)
              .update_all(queued_at: nil, updated_at: Time.current)
    end

    def set_queued_message_count(endpoint)
      actual = endpoint.messages.where.not(queued_at: nil).count
      return if endpoint.queued_message_count == actual

      endpoint.update!(queued_message_count: actual)
    end
  end
end
