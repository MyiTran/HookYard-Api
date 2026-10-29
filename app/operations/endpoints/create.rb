module Endpoints
  class Create < ApplicationOperation
    def call(project:, attributes:)
      Endpoint.transaction do
        project.lock!
        ensure_endpoint_slot_available!(project)
        endpoint = project.endpoints.create!(attributes)
        endpoint.rotate_signing_secret!
        endpoint
      end
    end

    private

    def ensure_endpoint_slot_available!(project)
      limit = Plans::Entitlements.endpoint_limit(project)
      return if project.endpoint_count < limit

      raise ApiError::PlanLimitExceededError.new(
        message: "The #{project.plan} plan allows at most #{limit} endpoints",
        field: 'endpoint_limit',
        used: project.endpoint_count,
        limit: limit
      )
    end
  end
end
