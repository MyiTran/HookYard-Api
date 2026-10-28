module CircuitProbes
  class Schedule < ApplicationOperation
    def call(now: Time.current)
      Endpoint.probe_due(now).find_each { |endpoint| CircuitProbes::RunJob.perform_later(endpoint.id) }
    end
  end
end
