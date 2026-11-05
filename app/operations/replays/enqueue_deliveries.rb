module Replays
  class EnqueueDeliveries < ApplicationOperation
    BATCH_SIZE = 500

    def initialize(job: Replays::DeliverJob)
      @job = job
    end

    def call(run:)
      return run unless claim(run)

      enqueue_batches(run)
      run.update!(materialized_at: Time.current)

      run
    end

    private

    attr_reader :job

    def claim(run)
      run.with_lock do
        run.reload
        run.materialized_at.nil? && run.mode == ReplayRun::MODE_BULK
      end
    end

    def enqueue_batches(run)
      cursor = nil

      loop do
        ids = queued_item_ids(run, cursor)
        break if ids.empty?

        ids.each { |id| job.perform_later(id) }
        cursor = ids.last
        break if ids.size < BATCH_SIZE
      end
    end

    def queued_item_ids(run, cursor)
      scope = run.replay_items.queued.reorder(:id).limit(BATCH_SIZE)
      scope = scope.where('replay_items.id > ?', cursor) if cursor

      scope.pluck(:id)
    end
  end
end
