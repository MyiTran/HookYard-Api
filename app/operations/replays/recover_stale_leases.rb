module Replays
  class RecoverStaleLeases < ApplicationOperation
    def call(now: Time.current)
      ReplayItem.with_expired_lease(now).pluck(:id).each { |item_id| recover!(item_id, now) }
    end

    private

    def recover!(item_id, now)
      item = ReplayItem.lock.find_by(id: item_id)
      return if item.nil?
      return unless item.lease_expired?(now)

      abandon_in_progress_attempt!(item)
      item.mark_failed!(
        error_type: ReplayItem::LEASE_EXPIRED_ERROR_TYPE,
        error_message: ReplayItem::LEASE_EXPIRED_MESSAGE
      )
    rescue ActiveRecord::RecordNotFound
      nil
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
