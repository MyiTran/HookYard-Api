module DeliveryMetrics
  class Backfill < ApplicationOperation
    BATCH_SIZE = DeliveryMetric::DEFAULT_BACKFILL_BATCH_SIZE

    def call(batch_size: BATCH_SIZE)
      validate_batch_size!(batch_size)

      total_processed = 0

      loop do
        processed = DeliveryMetric.backfill_batch(batch_size)
        total_processed += processed
        break if processed.zero?
      end

      total_processed
    end

    private

    def validate_batch_size!(batch_size)
      return if batch_size.is_a?(Integer) && batch_size.positive?

      raise ArgumentError, 'batch_size must be a positive integer'
    end
  end
end
