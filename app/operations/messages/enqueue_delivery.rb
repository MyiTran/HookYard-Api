module Messages
  class EnqueueDelivery < ApplicationOperation
    def call(message_ids:)
      message_ids.each { |message_id| enqueue(message_id) }
    end

    private

    def enqueue(message_id)
      Messages::DeliverJob.perform_later(message_id)
    rescue StandardError => e
      Rails.logger.error(
        "Webhook delivery enqueue failed for message #{message_id}: #{e.class}: #{e.message}"
      )
    end
  end
end
