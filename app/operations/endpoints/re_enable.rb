module Endpoints
  class ReEnable < ApplicationOperation
    CIRCUIT_OPEN_MESSAGE = 'Endpoint circuit is open and can only be closed by a successful delivery probe'

    def call(endpoint:)
      recovered = false

      Endpoint.transaction do
        endpoint.with_lock do
          endpoint.reload
          reject_open_circuit(endpoint)
          next if endpoint.enabled?

          endpoint.close_circuit!
          recovered = true
        end
      end

      Messages::ReleaseHeld.call(endpoint: endpoint) if recovered
      endpoint
    end

    private

    def reject_open_circuit(endpoint)
      return unless endpoint.circuit_open?

      raise ApiError::UnprocessableEntityError.new(message: CIRCUIT_OPEN_MESSAGE)
    end
  end
end
