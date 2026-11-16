module DeliveryAttempts
  class PurgeBodiesJob < ApplicationJob
    queue_as :low

    def perform
      DeliveryAttempts::PurgeBodies.call
    end
  end
end
