module Replays
  class ReleaseHeld < ApplicationOperation
    BATCH_SIZE = 100

    def initialize(job: Replays::DeliverJob)
      @job = job
    end

    def call(endpoint:)
      loop do
        ids = endpoint.replay_items.held.order(:created_at, :id).limit(BATCH_SIZE).pluck(:id)
        break if ids.empty?
        break if release(ids).zero?
      end

      endpoint
    end

    private

    attr_reader :job

    def release(ids)
      updated = ReplayItem.where(id: ids, status: ReplayItem::HELD_STATUS).update_all(
        status: ReplayItem::QUEUED_STATUS,
        hold_reason: nil,
        skip_reason: nil,
        updated_at: Time.current
      )
      ids.each { |id| job.perform_later(id) } if updated.positive?

      updated
    end
  end
end
