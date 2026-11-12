module CircuitProbes
  class Schedule < ApplicationOperation
    def call(now: Time.current)
      Endpoint.probe_due(now).find_each do |endpoint|
        enqueue_probe(endpoint, now: now)
      end
    end

    private

    def enqueue_probe(endpoint, now:)
      return unless endpoint.reserve_probe_lease!(at: now)

      reservation_token = endpoint.reload.circuit_probe_lease_expires_at.utc.iso8601(6)
      CircuitProbes::RunJob.perform_later(endpoint.id, reservation_token)
    rescue StandardError
      endpoint.release_probe_reservation!(reservation_token) if reservation_token
      raise
    end
  end
end
