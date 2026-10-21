module Messages
  class DeliverJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(message_id)
      Messages::Deliver.call(message: Message.find(message_id))
    end
  end
end
