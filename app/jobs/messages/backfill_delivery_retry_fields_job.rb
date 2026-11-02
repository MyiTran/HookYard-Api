module Messages
  class BackfillDeliveryRetryFieldsJob < ApplicationJob
    queue_as :low

    def perform
      Messages::BackfillDeliveryRetryFields.call
    end
  end
end
