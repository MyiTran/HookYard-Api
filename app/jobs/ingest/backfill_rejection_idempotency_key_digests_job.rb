module Ingest
  class BackfillRejectionIdempotencyKeyDigestsJob < ApplicationJob
    queue_as :low

    BATCH_SIZE = 500
    MAX_BATCHES = 100
    RAW_KEY_COLUMN = 'idempotency_key'
    DIGEST_COLUMN = 'idempotency_key_digest'

    def perform(last_id = nil, batch_number = 0, batch_size = BATCH_SIZE)
      return unless columns_ready?

      rejection_ids = pending_rejection_ids(last_id, batch_size)
      return if rejection_ids.empty?

      updated = backfill_batch(rejection_ids)
      Rails.logger.info("ingest_rejection digest backfill batch: updated=#{updated}")

      enqueue_next(rejection_ids.last, batch_number, batch_size) if rejection_ids.size == batch_size
    end

    private

    def columns_ready?
      IngestRejection.reset_column_information

      IngestRejection.column_names.include?(RAW_KEY_COLUMN) &&
        IngestRejection.column_names.include?(DIGEST_COLUMN)
    end

    def pending_rejection_ids(last_id, batch_size)
      scope = IngestRejection
              .where.not(RAW_KEY_COLUMN => nil)
              .where(DIGEST_COLUMN => nil)
              .order(:id)
              .limit(batch_size)
      scope = scope.where('ingest_rejections.id > ?', last_id) if last_id
      scope.pluck(:id)
    end

    def backfill_batch(rejection_ids)
      ApplicationRecord.connection.exec_update(<<~SQL.squish, 'BackfillRejectionIdempotencyKeyDigestsJob')
        UPDATE ingest_rejections
        SET idempotency_key_digest = encode(digest(idempotency_key, 'sha256'), 'hex')
        WHERE id IN (#{quoted_ids(rejection_ids)})
          AND idempotency_key IS NOT NULL
          AND idempotency_key_digest IS NULL
      SQL
    end

    def enqueue_next(last_id, batch_number, batch_size)
      if batch_number + 1 >= MAX_BATCHES
        remaining = IngestRejection
                    .where.not(RAW_KEY_COLUMN => nil)
                    .where(DIGEST_COLUMN => nil)
                    .where('ingest_rejections.id > ?', last_id)
                    .count
        if remaining.positive?
          Rails.logger.warn(
            "ingest_rejection digest backfill stopped at MAX_BATCHES=#{MAX_BATCHES}; " \
            "#{remaining} rejections may remain; " \
            're-run `rails data_backfills:enqueue_plan_backfills` to continue'
          )
        end
        return
      end

      self.class.perform_later(last_id, batch_number + 1, batch_size)
    end

    def quoted_ids(ids)
      ids.map { |id| ApplicationRecord.connection.quote(id) }.join(', ')
    end
  end
end
