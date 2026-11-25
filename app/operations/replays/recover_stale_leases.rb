module Replays
  class RecoverStaleLeases < ApplicationOperation
    def call(now: Time.current)
      ReplayItem.with_expired_lease(now).pluck(:id).each { |item_id| recover!(item_id, now) }
    end

    private

    def recover!(item_id, now)
      endpoint_id = ReplayItem.where(id: item_id).pick(:endpoint_id)
      return if endpoint_id.nil?

      Endpoint.find(endpoint_id).with_lock do
        recover_locked_item!(item_id, now)
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def recover_locked_item!(item_id, now)
      item = ReplayItem.lock.find_by(id: item_id)
      return if item.nil?
      return unless item.lease_expired?(now)

      attempt = item.delivery_attempt
      return finalize_recorded_result!(item, attempt, now) if attempt&.completed?

      abandon_in_progress_attempt!(item)
      item.mark_failed!(
        error_type: ReplayItem::LEASE_EXPIRED_ERROR_TYPE,
        error_message: ReplayItem::LEASE_EXPIRED_MESSAGE,
        at: now
      )
    end

    # A completed replay attempt already holds the authoritative HTTP result, so recovering it
    # must not rewrite the terminal state: the recorded evidence drives the normal transition.
    def finalize_recorded_result!(item, attempt, now)
      Replays::FinalizeResult.call(
        item: item, attempt: attempt, result: attempt.recorded_result, at: now
      )
    end

    def abandon_in_progress_attempt!(item)
      attempt = item.delivery_attempt
      return if attempt.nil? || attempt.completed?

      attempt.update!(
        error_type: DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE,
        error_message: DeliveryAttempt::LEASE_EXPIRED_MESSAGE
      )
    end
  end
end
