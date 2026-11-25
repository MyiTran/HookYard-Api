module Replays
  class FinalizeResult < ApplicationOperation
    # Callers hold the endpoint and replay item row locks so the terminal state, the circuit
    # accounting and the attempt metric stay exactly-once against concurrent recovery.
    def call(item:, attempt:, result:, at: Time.current)
      @item = item
      @attempt = attempt
      @result = result
      @at = at

      DeliveryMetric.record_attempt!(attempt)
      finish_item
      resolve_circuit
    end

    private

    attr_reader :item, :attempt, :result, :at

    def finish_item
      if Webhooks::CircuitPolicy.success?(result)
        item.mark_succeeded!(at: at)
        item.message.mark_succeeded_by_replay!(at: at)
      else
        item.mark_failed!(error_type: failure_type, error_message: failure_message, at: at)
      end
    end

    def resolve_circuit
      endpoint = item.endpoint.reload

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

    def failure_type
      result.error? ? result.error_type : nil
    end

    def failure_message
      return nil unless result.error?

      DeliveryAttempt.truncate_error_message(result.error)
    end
  end
end
