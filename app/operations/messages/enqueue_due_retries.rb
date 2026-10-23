module Messages
  class EnqueueDueRetries < ApplicationOperation
    def call(now: Time.current)
      Message.due_for_delivery(now).pluck(:id).each { |message_id| Messages::DeliverJob.perform_later(message_id) }
    end
  end
end
