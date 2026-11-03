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
      account = project.billing_owner
      limit = Plans::Entitlements.endpoint_limit(account)
      used = project.endpoint_count
      return if used < limit

      raise ApiError::PlanLimitExceededError.new(
        message: "The #{account.plan} plan allows at most #{limit} endpoints per project",
        field: 'endpoint_limit',
        used: used,
        limit: limit
      )
    end
  end
end
