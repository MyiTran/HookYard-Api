module CircuitProbes
  class RunJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: false

    discard_on ActiveRecord::RecordNotFound

    def perform(endpoint_id, reservation_token = nil)
      CircuitProbes::Run.call(endpoint: Endpoint.find(endpoint_id), reservation_token: reservation_token)
    end
  end
end
