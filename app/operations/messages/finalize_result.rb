module Messages
  class FinalizeResult < ApplicationOperation
    # Callers hold the endpoint and message row locks so the transition, the circuit
    # accounting and the attempt metric stay exactly-once against concurrent recovery.
    def call(message:, attempt:, result:, at: Time.current)
      @message = message
      @attempt = attempt
      @result = result
      @at = at

      DeliveryMetric.record_attempt!(attempt)
      retry_at = transition
      resolve_circuit
      hold_if_circuit_blocked(retry_at)

      retry_at
    end

    private

    attr_reader :message, :attempt, :result, :at

    def transition
      if Webhooks::CircuitPolicy.success?(result)
        message.mark_succeeded!(at: at)
        return nil
      end

      retry_at = next_retry_at
      if retry_at
        message.schedule_retry!(at: retry_at)
        retry_at
      else
        message.mark_failed!(at: at)
        nil
      end
    end

    def next_retry_at
      return nil unless Webhooks::DeliveryPolicy.retryable?(result) && message.retries_available?

      delay = Webhooks::DeliveryPolicy.retry_delay(message.attempt_count, project: project)
      delay && at + delay
    end

    def resolve_circuit
      endpoint = message.endpoint.reload

      if Webhooks::CircuitPolicy.success?(result)
        reset_circuit_failures(endpoint)
      else
        endpoint.register_circuit_failure!(result, at: at)
      end
    end

    def reset_circuit_failures(endpoint)
      return unless endpoint.enabled?
      return if endpoint.circuit_failure_count.zero?

      endpoint.update!(circuit_failure_count: 0)
    end

    def hold_if_circuit_blocked(retry_at)
      return if retry_at.nil?

      endpoint = message.endpoint.reload
      return if endpoint.enabled?
      return if message.reload.held?

      message.hold!(reason: endpoint.circuit_hold_reason, at: at)
    end

    def project
      message.endpoint.project
    end
  end
end
