module Messages
  class PendingDeliveryRecoveryJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: false

    def perform
      Messages::EnqueuePending.call
    end
  end
end
