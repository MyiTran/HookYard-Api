class ProjectSerializer < ApplicationSerializer
  identifier :id

  fields :name, :plan, :created_at, :updated_at

  field :current_user_role do |project, options|
    project.project_memberships.find { |membership| membership.user_id == options[:current_user]&.id }&.role
  end

  field :endpoint_limit do |project|
    Plans::Entitlements.endpoint_limit(project)
  end

  field :monthly_delivery_limit do |project|
    Plans::Entitlements.monthly_delivery_limit(project)
  end

  field :usage do |project, options|
    limit = Plans::Entitlements.monthly_delivery_limit(project)
    summary = options[:usage_summary]
    used = summary ? summary.deliveries_for(project) : project.deliveries_used_in_period

    {
      endpoint_count: summary ? summary.endpoint_count_for(project) : project.endpoint_count,
      deliveries_this_period: used,
      deliveries_remaining: [limit - used, 0].max,
      period_starts_at: ProjectUsagePeriod.period_starts_at.iso8601,
      period_ends_at: ProjectUsagePeriod.period_ends_at.iso8601
    }
  end
end
