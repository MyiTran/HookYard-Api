module Projects
  class Create < ApplicationOperation
    def call(user:, attributes:)
      Project.transaction do
        user.lock!
        ensure_project_slot_available!(user)
        project = Project.create!(attributes.merge(billing_owner: user))
        project.project_memberships.create!(user: user, role: :owner)
        project
      end
    end

    private

    def ensure_project_slot_available!(account)
      limit = Plans::Entitlements.project_limit(account)
      used = account.owned_project_count
      return if used < limit

      raise ApiError::PlanLimitExceededError.new(
        message: "The #{account.plan} plan allows at most #{limit} projects",
        field: 'project_limit',
        used: used,
        limit: limit
      )
    end
  end
end
