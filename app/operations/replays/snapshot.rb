module Replays
  class Snapshot < ApplicationOperation
    BATCH_SIZE = 500
    ACTIVE_MESSAGE_INDEX = 'index_replay_items_on_active_message'

    def call(run:, as_of: Time.current)
      Replays::BulkPolicy.enforce!(project: run.project, filters: filters(run), as_of: as_of)

      run.update!(requested_count: count_candidates(run, as_of))
      snapshot_batches(run, as_of)

      enforce_inserted_cap!(run)

      run
    end

    private

    def count_candidates(run, as_of)
      ReplayCandidatesQuery.count(candidate_scope(run), eligible: false, as_of: as_of, **filters(run))
    end

    def snapshot_batches(run, as_of)
      cursor = nil

      loop do
        batch = scan(run, as_of, cursor)
        break if batch.empty?

        insert_items(run, batch)
        cursor = batch.last.id
        break if batch.size < BATCH_SIZE
      end
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

    # A write that started before the confirmation cutoff can commit after the cap count
    # ran, so the count alone can under-report. This second check runs before the caller's
    # transaction commits, which rolls the whole run back instead of keeping an oversized set.
    def enforce_inserted_cap!(run)
      inserted = run.replay_items.count
      return unless Replays::BulkPolicy.over_limit?(inserted)

      Replays::BulkPolicy.raise_limit_error!(eligible: inserted)
    end

    def insert_items(run, messages)
      now = Time.current
      rows = messages.map { |message| item_attributes(run, message, now) }

      ReplayItem.insert_all(rows, unique_by: ACTIVE_MESSAGE_INDEX)
    end

    def item_attributes(run, message, now)
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
