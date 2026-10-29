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
