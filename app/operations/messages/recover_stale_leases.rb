module Messages
  class RecoverStaleLeases < ApplicationOperation
    def call(now: Time.current)
      stale_message_ids(now).each { |message_id| recover(message_id, now) }
    end

    private

    def stale_message_ids(now)
      Message.with_expired_lease(now).pluck(:id)
    end

    def recover(message_id, now)
      endpoint_id = Message.where(id: message_id).pick(:endpoint_id)
      return if endpoint_id.nil?

      Endpoint.find(endpoint_id).with_lock do
        recover_locked_message(message_id, now)
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def recover_locked_message(message_id, now)
      message = Message.lock.find_by(id: message_id)
      return if message.nil?
      return unless message.lease_expired?(now)

      abandon_in_progress_attempt(message)
      return message.mark_failed!(at: now) unless message.retries_available?

      message.schedule_retry!(at: now + retry_delay_for(message))
    end

    def abandon_in_progress_attempt(message)
      attempt = message.delivery_attempts.where(response_status: nil, error_type: nil).order(:attempt_number).last
      return if attempt.nil?

      attempt.update!(
        error_type: DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE,
        error_message: DeliveryAttempt::LEASE_EXPIRED_MESSAGE
      )
    end

    def retry_delay_for(message)
      Webhooks::DeliveryPolicy.retry_delay([message.attempt_count, 1].max)
    end
  end
end
