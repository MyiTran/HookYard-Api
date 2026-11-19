module Replays
  class Snapshot < ApplicationOperation
    BATCH_SIZE = 500
    ACTIVE_MESSAGE_INDEX = 'index_replay_items_on_active_message'

    def call(run:, as_of: Time.current)
      ApplicationRecord.transaction do
        Replays::BulkPolicy.enforce!(project: run.project, filters: filters(run), as_of: as_of)
        run.update!(requested_count: count_candidates(run, as_of))

        inserted_ids = snapshot_batches(run, as_of)
        enforce_inserted_cap!(inserted_ids.size)
        reserve_quota_for_inserted!(run, inserted_ids)

        run
      end
    end

    private

    def count_candidates(run, as_of)
      ReplayCandidatesQuery.count(candidate_scope(run), eligible: false, as_of: as_of, **filters(run))
    end

    def snapshot_batches(run, as_of)
      inserted_ids = []
      cursor = nil

      loop do
        batch = scan(run, as_of, cursor)
        break if batch.empty?

        inserted_ids.concat(insert_items(run, batch))
        cursor = batch.last.id
        break if batch.size < BATCH_SIZE
      end

      inserted_ids
    end

    def scan(run, as_of, cursor)
      scope = candidates(run, as_of).reorder(:id).limit(BATCH_SIZE)
      scope = scope.where('messages.id > ?', cursor) if cursor

      scope.to_a
    end

    def candidates(run, as_of)
      ReplayCandidatesQuery.call(candidate_scope(run), as_of: as_of, **filters(run))
    end

    def candidate_scope(run)
      ReplayCandidatesQuery.for_project(run.project)
    end

    def filters(run)
      run.filters.symbolize_keys
    end

    # A write that started before the confirmation cutoff can commit after the eligible count
    # ran, so the eligible count can under-report. This second check runs on the rows that were
    # actually inserted and inside the same transaction, so an oversized run rolls back.
    def enforce_inserted_cap!(inserted)
      return unless Replays::BulkPolicy.over_limit?(inserted)

      Replays::BulkPolicy.raise_limit_error!(eligible: inserted)
    end

    def reserve_quota_for_inserted!(run, inserted_ids)
      return if inserted_ids.empty?

      at = Time.current
      Plans::Quota.reserve_deliveries!(project: run.project, quantity: inserted_ids.size, at: at)
      ReplayItem.where(id: inserted_ids).update_all(quota_reserved_at: at)
    end

    def insert_items(run, messages)
      rows = messages.map { |message| item_attributes(run, message) }

      ReplayItem.insert_all(rows, unique_by: ACTIVE_MESSAGE_INDEX).rows.flatten
    end

    def item_attributes(run, message)
      now = Time.current
      held = message.endpoint.circuit_open?

      {
        replay_run_id: run.id,
        message_id: message.id,
        endpoint_id: message.endpoint_id,
        status: held ? ReplayItem::HELD_STATUS : ReplayItem::QUEUED_STATUS,
        hold_reason: held ? ReplayItem::HOLD_REASON_CIRCUIT_OPEN : nil,
        created_at: now,
        updated_at: now
      }
    end
  end
end
