module Replays
  class Create < ApplicationOperation
    REASON_MESSAGES = {
      Eligibility::REASON_NOT_TERMINAL => 'Only messages that terminally failed can be replayed',
      Eligibility::REASON_NOT_FAILED => 'Only failed messages can be replayed',
      Eligibility::REASON_HELD => 'Held messages can not be replayed',
      Eligibility::REASON_ENDPOINT_ARCHIVED => 'Messages of archived endpoints can not be replayed',
      Eligibility::REASON_ENDPOINT_PAUSED => 'This endpoint is paused. Resume it before replaying this delivery.',
      Eligibility::REASON_ENDPOINT_DISABLED => 'Messages of disabled endpoints can not be replayed',
      Eligibility::REASON_REPLAY_IN_PROGRESS => 'A replay for this message is already in progress'
    }.freeze

    def initialize(job: Replays::DeliverJob)
      @job = job
    end

    def call(message:, actor:)
      run, item = ReplayRun.transaction do
        message.lock!
        reject_ineligible(message)
        build_run(message, actor)
      end

      job.perform_later(item.id) if item.queued?

      run
    rescue ActiveRecord::RecordNotUnique
      reject_ineligible_replay
    end

    private

    attr_reader :job

    def build_run(message, actor)
      endpoint = message.endpoint
      run = ReplayRun.create!(
        project: endpoint.project,
        actor: actor,
        mode: ReplayRun::MODE_SINGLE,
        requested_count: 1,
        materialized_at: Time.current
      )
      item = run.replay_items.create!(
        message: message,
        endpoint: endpoint,
        status: initial_status(endpoint),
        hold_reason: initial_hold_reason(endpoint)
      )

      [run, item]
    end

    def reject_ineligible(message)
      result = Eligibility.for_message(message)
      return if result.allowed?

      raise ApiError::UnprocessableEntityError.new(
        message: REASON_MESSAGES.fetch(result.reason),
        errors: [{ field: 'message', message: result.reason }]
      )
    end

    def reject_ineligible_replay
      raise ApiError::UnprocessableEntityError.new(
        message: REASON_MESSAGES.fetch(Eligibility::REASON_REPLAY_IN_PROGRESS),
        errors: [{ field: 'message', message: Eligibility::REASON_REPLAY_IN_PROGRESS }]
      )
    end

    def initial_status(endpoint)
      endpoint.circuit_open? ? ReplayItem::HELD_STATUS : ReplayItem::QUEUED_STATUS
    end

    def initial_hold_reason(endpoint)
      endpoint.circuit_open? ? ReplayItem::HOLD_REASON_CIRCUIT_OPEN : nil
    end
  end
end
