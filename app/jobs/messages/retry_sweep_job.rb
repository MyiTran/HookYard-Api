module Messages
  class RetrySweepJob < ApplicationJob
    queue_as :default
    sidekiq_options retry: false

    def perform
      Messages::RecoverStaleLeases.call
      Messages::EnqueueDueRetries.call
      CircuitProbes::Schedule.call
    end
  end
end
