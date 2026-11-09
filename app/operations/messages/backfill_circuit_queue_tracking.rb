module Messages
  # Circuit protection introduced two derived columns whose historical rows predate
  # the writers that maintain them: messages.queued_at (the endpoint queue slot the
  # counter projects) and endpoints.circuit_disable_at (the deadline of the window
  # that was open when the circuit opened). Both are repaired here in bounded
  # batches so no schema migration has to mutate production data.
  class BackfillCircuitQueueTracking < ApplicationOperation
    BATCH_SIZE = 500
    SLOT_STATUSES = %w[pending delivering].freeze
    QUEUED_AT_COLUMN = 'queued_at'
    CIRCUIT_DISABLE_AT_COLUMN = 'circuit_disable_at'

    def call(batch_size: BATCH_SIZE)
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ArgumentError, 'batch_size must be a positive integer'
      end

      slots = backfill_queued_at(batch_size)
      endpoints_reconciled = reconcile_endpoint_queues(batch_size)

      {
        messages_scanned: slots[:scanned],
        queued_at_backfilled: slots[:updated],
        endpoints_reconciled: endpoints_reconciled,
        circuit_disable_at_backfilled: backfill_circuit_disable_at(batch_size)
      }
    end

    private

    def backfill_queued_at(batch_size)
      return { scanned: 0, updated: 0 } unless column_present?(Message, QUEUED_AT_COLUMN)

      scanned = 0
      updated = 0

      each_batch(Message.order(:id), batch_size) do |message_ids|
        scanned += message_ids.size
        updated += update_queued_at(message_ids)
      end

      { scanned: scanned, updated: updated }
    end

    def update_queued_at(message_ids)
      ApplicationRecord.connection.exec_update(<<~SQL.squish, 'BackfillCircuitQueueTracking queued_at')
        UPDATE messages
        SET queued_at = COALESCE(messages.created_at, now())
        WHERE messages.id IN (#{quoted_ids(message_ids)})
          AND messages.queued_at IS NULL
          AND messages.status IN (#{quoted_statuses})
      SQL
    end

    def reconcile_endpoint_queues(batch_size)
      return 0 unless column_present?(Message, QUEUED_AT_COLUMN)

      reconciled = 0

      each_batch(Endpoint.order(:id), batch_size) do |endpoint_ids|
        Endpoint.where(id: endpoint_ids).find_each do |endpoint|
          Messages::ReconcileQueue.call(endpoint: endpoint)
          reconciled += 1
        end
      end

      reconciled
    end

    def backfill_circuit_disable_at(batch_size)
      return 0 unless column_present?(Endpoint, CIRCUIT_DISABLE_AT_COLUMN)

      backfilled = 0

      each_batch(Endpoint.circuit_open.order(:id), batch_size) do |endpoint_ids|
        backfilled += update_circuit_disable_at(endpoint_ids)
      end

      backfilled
    end

    def update_circuit_disable_at(endpoint_ids)
      ApplicationRecord.connection.exec_update(<<~SQL.squish, 'BackfillCircuitQueueTracking circuit_disable_at')
        UPDATE endpoints
        SET circuit_disable_at = endpoints.circuit_opened_at + INTERVAL '#{disable_window_seconds} seconds'
        WHERE endpoints.id IN (#{quoted_ids(endpoint_ids)})
          AND endpoints.circuit_opened_at IS NOT NULL
          AND endpoints.circuit_disable_at IS NULL
      SQL
    end

    def each_batch(scope, batch_size)
      last_id = nil

      loop do
        batch_scope = scope.limit(batch_size)
        batch_scope = batch_scope.where("#{scope.table_name}.id > ?", last_id) if last_id
        ids = batch_scope.pluck(:id)
        break if ids.empty?

        yield ids
        last_id = ids.last
        break if ids.size < batch_size
      end
    end

    def column_present?(model, column)
      model.reset_column_information

      model.column_names.include?(column)
    end

    def disable_window_seconds
      Webhooks::CircuitPolicy.disable_window.to_i
    end

    def quoted_ids(ids)
      ids.map { |id| ApplicationRecord.connection.quote(id) }.join(', ')
    end

    def quoted_statuses
      SLOT_STATUSES.map { |status| ApplicationRecord.connection.quote(status) }.join(', ')
    end
  end
end
