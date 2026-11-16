module Messages
  class BackfillCircuitQueueTrackingJob < ApplicationJob
    queue_as :low

    def perform
      Messages::BackfillCircuitQueueTracking.call
    end
  end
end
