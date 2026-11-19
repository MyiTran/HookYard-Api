module Replays
  class CreateBulk < ApplicationOperation
    PLAN_REQUIRED_MESSAGE = 'Bulk replay requires the pro plan'

    def initialize(job: Replays::BulkJob)
      @job = job
    end

    def call(project:, actor:, filters:)
      raise ApiError::NotAuthorizedError.new(PLAN_REQUIRED_MESSAGE) unless project.pro?

      as_of = Time.current
      run = ReplayRun.create!(
        project: project,
        actor: actor,
        mode: ReplayRun::MODE_BULK,
        filters: ReplayRun.normalized_filters(filters),
        as_of: as_of
      )

      job.perform_later(run.id)
      run
    end

    private

    attr_reader :job
  end
end
