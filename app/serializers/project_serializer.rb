class ProjectSerializer < ApplicationSerializer
  identifier :id

  fields :name, :plan, :created_at, :updated_at

  field :current_user_role do |project, options|
    project.project_memberships.find { |membership| membership.user_id == options[:current_user]&.id }&.role
  end

  field :endpoint_limit do |project|
    account = project.effective_billing_owner
    Plans::Entitlements.endpoint_limit(account) if account
  end

  field :monthly_delivery_limit do |project|
    account = project.effective_billing_owner
    Plans::Entitlements.monthly_delivery_limit(account) if account
  end

  field :usage do |project, options|
    account = project.effective_billing_owner
    limit = Plans::Entitlements.monthly_delivery_limit(account) if account
    summary = options[:usage_summary]
    used = summary&.deliveries_for(project) || account&.deliveries_used_in_period || 0

    {
      endpoint_count: summary ? summary.endpoint_count_for(project) : project.endpoint_count,
      deliveries_this_period: used,
      deliveries_remaining: limit ? [limit - used, 0].max : nil,
      period_starts_at: UserUsagePeriod.period_starts_at.iso8601,
      period_ends_at: UserUsagePeriod.period_ends_at.iso8601
    }
  end
end
