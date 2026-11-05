module Webhooks
  module CircuitTracker
    module_function

    def apply(endpoint:, result:)
      if CircuitPolicy.success?(result)
        reset(endpoint)
      elsif CircuitPolicy.counted_failure?(result)
        endpoint.register_circuit_failure!
      end
    end

    def reset(endpoint)
      return unless endpoint.enabled?
      return if endpoint.circuit_failure_count.zero?

      endpoint.update!(circuit_failure_count: 0)
    end
  end
end
