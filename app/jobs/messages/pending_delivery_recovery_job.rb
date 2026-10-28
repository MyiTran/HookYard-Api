module Messages
  class PendingDeliveryRecoveryJob < ApplicationJob
    queue_as :default

    def perform
      Messages::EnqueuePending.call
    end
  end
end
