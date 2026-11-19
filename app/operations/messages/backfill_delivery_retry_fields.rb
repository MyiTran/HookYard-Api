module Messages
  class BackfillDeliveryRetryFields < ApplicationOperation
    BATCH_SIZE = 500
    RETRY_COLUMNS = %w[attempt_count terminal_at].freeze
    TERMINAL_STATUSES = %w[succeeded failed].freeze

    def call(batch_size: BATCH_SIZE)
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ArgumentError, 'batch_size must be a positive integer'
      end

      return unless retry_columns_present?

      each_batch(batch_size) do |message_ids|
        backfill_attempt_counts(message_ids)
        backfill_terminal_timestamps(message_ids)
      end
    end

    private

    def retry_columns_present?
      Message.reset_column_information

      (RETRY_COLUMNS - Message.column_names).empty?
    end

    def each_batch(batch_size)
      last_id = nil

      loop do
        message_ids = batch_scope(last_id, batch_size).pluck(:id)
        break if message_ids.empty?

        yield message_ids
        last_id = message_ids.last
        break if message_ids.size < batch_size
      end
    end

    def batch_scope(last_id, batch_size)
      scope = Message.order(:id).limit(batch_size)
      last_id.nil? ? scope : scope.where('messages.id > ?', last_id)
    end

    def backfill_attempt_counts(message_ids)
      Message.connection.exec_update(<<~SQL.squish, 'BackfillDeliveryRetryFields attempt_count')
        UPDATE messages
        SET attempt_count = recorded_attempts.attempt_count
        FROM (
          SELECT message_id, COUNT(*) AS attempt_count
          FROM delivery_attempts
          WHERE message_id IN (#{quoted_message_ids(message_ids)})
          GROUP BY message_id
        ) AS recorded_attempts
        WHERE messages.id = recorded_attempts.message_id
          AND messages.attempt_count < recorded_attempts.attempt_count
      SQL
    end

    def backfill_terminal_timestamps(message_ids)
      Message.where(id: message_ids, terminal_at: nil, status: TERMINAL_STATUSES)
             .update_all('terminal_at = updated_at')
    end

    def quoted_message_ids(message_ids)
      message_ids.map { |message_id| Message.connection.quote(message_id) }.join(', ')
    end
  end
end
