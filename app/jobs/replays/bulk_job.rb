module Replays
  class BulkJob < ApplicationJob
    queue_as :low
    sidekiq_options retry: false

    discard_on ActiveRecord::RecordNotFound

    def perform(replay_run_id)
      Replays::EnqueueDeliveries.call(run: ReplayRun.find(replay_run_id))
    end
  end
end
