module Messages
  class EnqueueDueRetries < ApplicationOperation
    def call(now: Time.current)
      Messages::EnqueueDelivery.call(message_ids: Message.due_for_delivery(now).pluck(:id))
    end
  end
end
