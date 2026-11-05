module Replays
  class CreateBulk < ApplicationOperation
    PLAN_REQUIRED_MESSAGE = 'Bulk replay requires the pro plan'

    def initialize(job: Replays::BulkJob)
      @job = job
    end

    def call(project:, actor:, filters:)
      raise ApiError::NotAuthorizedError.new(PLAN_REQUIRED_MESSAGE) unless project.pro?

      # Frozen confirmation instant: the cap check, the requested count and every snapshot
      # batch filter on it, so a message written after confirmation can never enter the run
      # and the confirmed set cannot grow between batches.
      as_of = Time.current

      Replays::BulkPolicy.enforce!(project: project, filters: filters, as_of: as_of)

      run = build_run(project: project, actor: actor, filters: filters, as_of: as_of)
      job.perform_later(run.id)

      run
    end

    private

    attr_reader :job

    def build_run(project:, actor:, filters:, as_of:)
      ReplayRun.transaction do
        run = ReplayRun.create!(
          project: project,
          actor: actor,
          mode: ReplayRun::MODE_BULK,
          filters: ReplayRun.normalized_filters(filters)
        )
        Replays::Snapshot.call(run: run, as_of: as_of)

        run
      end
    end
  end
end
