module Messages
  # While an endpoint is not enabled every non-terminal message without an active
  # delivery lease is held, so the pending set is the circuit backlog. Releasing
  # all of it clears pre-circuit retry timestamps that would otherwise keep a
  # recovered endpoint from draining.
  class ReleaseHeld < ApplicationOperation
    def call(endpoint:, except_ids: [])
      released_ids = []

      loop do
        message_ids = releasable_ids(endpoint, except_ids + released_ids)
        break if message_ids.empty?

        release(message_ids)
        released_ids.concat(message_ids)
        Messages::EnqueueDelivery.call(message_ids: message_ids)
      end

      Messages::ReconcileQueue.call(endpoint: endpoint)
    end

    private

    def releasable_ids(endpoint, excluded_ids)
      scope = endpoint.messages.pending
      scope = scope.where.not(id: excluded_ids) if excluded_ids.any?

      scope.order(:created_at, :id)
           .limit(Webhooks::CircuitPolicy::RELEASE_BATCH_SIZE)
           .pluck(:id)
    end

    def release(message_ids)
      Message.pending.where(id: message_ids)
             .update_all(held_at: nil, hold_reason: nil, next_retry_at: nil, updated_at: Time.current)
    end
  end
end
