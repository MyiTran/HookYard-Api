module Messages
  class EnqueuePending < ApplicationOperation
    def call(now: Time.current)
      Messages::EnqueueDelivery.call(message_ids: Message.pending_before(enqueue_cutoff(now)).pluck(:id))
    end

    private

    def enqueue_cutoff(now)
      now - Constants::WEBHOOK_DELIVERY_ENQUEUE_GRACE_SECONDS.seconds
    end
  end
end
