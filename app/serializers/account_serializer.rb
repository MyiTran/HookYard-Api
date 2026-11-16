class AccountSerializer < ApplicationSerializer
  identifier :id

  field :plan

  field :project_limit do |account|
    Plans::Entitlements.project_limit(account)
  end

  field :endpoint_limit_per_project do |account|
    Plans::Entitlements.endpoint_limit(account)
  end

  field :monthly_delivery_limit do |account|
    Plans::Entitlements.monthly_delivery_limit(account)
  end

  field :body_retention_days do |account|
    Plans::Entitlements.body_retention_days(account)
  end

  field :available_plans do
    Plans::Entitlements::DEFINITIONS.map do |plan, definition|
      {
        plan: plan,
        project_limit: definition.project_limit,
        endpoint_limit_per_project: definition.endpoint_limit,
        monthly_delivery_limit: definition.monthly_delivery_limit,
        body_retention_days: definition.body_retention_days
      }
    end
  end

  field :usage do |account|
    limit = Plans::Entitlements.monthly_delivery_limit(account)
    used = account.deliveries_used_in_period

    {
      project_count: account.owned_project_count,
      deliveries_this_period: used,
      deliveries_remaining: [limit - used, 0].max,
      period_starts_at: UserUsagePeriod.period_starts_at.iso8601,
      period_ends_at: UserUsagePeriod.period_ends_at.iso8601
    }
  end
end
