module Messages
  class RetrySweepJob < ApplicationJob
    queue_as :default

    def perform
      Messages::RecoverStaleLeases.call
      Messages::EnqueueDueRetries.call
    end
  end
end
