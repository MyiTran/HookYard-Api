module DeliveryMetrics
  class BackfillJob < ApplicationJob
    queue_as :low

    def perform
      DeliveryMetrics::Backfill.call
    end
  end
end
