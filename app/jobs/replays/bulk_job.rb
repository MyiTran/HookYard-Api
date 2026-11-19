module Replays
  class BulkJob < ApplicationJob
    queue_as :low
    sidekiq_options retry: 5

    discard_on ActiveRecord::RecordNotFound

    def perform(replay_run_id)
      run = ReplayRun.find(replay_run_id)
      return if run.failed?
      return if run.materialized_at.present?

      Replays::Snapshot.call(run: run, as_of: run.as_of)
      Replays::EnqueueDeliveries.call(run: run)
    rescue ApiError::PlanLimitExceededError
      run.fail!(reason: ReplayRun::FAILURE_REASON_QUOTA)
    rescue ApiError::BulkReplayLimitExceededError
      run.fail!(reason: ReplayRun::FAILURE_REASON_OVER_LIMIT)
    end
  end
end
