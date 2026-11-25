module Messages
  class RecoverStaleLeases < ApplicationOperation
    def call(now: Time.current)
      stale_message_ids(now).each { |message_id| recover!(message_id, now) }
    end

    private

    def stale_message_ids(now)
      Message.with_expired_lease(now).pluck(:id)
    end

    def recover!(message_id, now)
      endpoint_id = Message.where(id: message_id).pick(:endpoint_id)
      return if endpoint_id.nil?

      Endpoint.find(endpoint_id).with_lock do
        recover_locked_message!(message_id, now)
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def recover_locked_message!(message_id, now)
      message = Message.lock.find_by(id: message_id)
      return if message.nil?
      return unless message.lease_expired?(now)

      attempt = completed_current_attempt(message)
      return finalize_recorded_result!(message, attempt, now) if attempt

      abandon_in_progress_attempt!(message)
      recover_endpoint!(message, now)
    end

    # A completed attempt already holds the authoritative HTTP result, so recovering it must
    # not send the request again: the recorded evidence drives the normal result transition.
    def finalize_recorded_result!(message, attempt, now)
      Messages::FinalizeResult.call(
        message: message, attempt: attempt, result: attempt.recorded_result, at: now
      )
    end

    def completed_current_attempt(message)
      attempt = message.delivery_attempts.find_by(attempt_number: message.attempt_count)
      return nil if attempt.nil? || attempt.replay? || !attempt.completed?

      attempt
    end

    def recover_endpoint!(message, now)
      endpoint = message.endpoint.reload

      return message.hold!(reason: endpoint.circuit_hold_reason, at: now) unless endpoint.enabled?

      retry_at = retry_at_for(message, now)
      return message.mark_failed!(at: now) if retry_at.nil?

      message.schedule_retry!(at: retry_at)
    end

    def abandon_in_progress_attempt!(message)
      attempt = message.delivery_attempts.where(response_status: nil, error_type: nil).order(:attempt_number).last
      return if attempt.nil?

      attempt.update!(
        error_type: DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE,
        error_message: DeliveryAttempt::LEASE_EXPIRED_MESSAGE
      )
    end

    def retry_at_for(message, now)
      return nil unless message.retries_available?

      delay = Webhooks::DeliveryPolicy.retry_delay([message.attempt_count, 1].max, project: message.endpoint.project)
      delay && now + delay
    end
  end
end
