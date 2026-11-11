class UserDashboardQuery < ApplicationQuery
  PERIOD_DAYS = 7
  PERIOD_LABEL = 'Last 7 days'
  MAX_PROJECTS = 5

  def call(user:, at: Time.current)
    projects = ProjectPolicy::Scope.new(user, Project).resolve
                                 .preload(:project_memberships, :billing_owner)
                                 .to_a

    build_result(user, projects, at)
  end

  private

  def build_result(user, projects, at)
    project_ids = projects.map(&:id)
    endpoint_counts, active_endpoint_counts, open_circuit_counts, open_circuit_total =
      endpoint_aggregates(project_ids)
    delivering, pending_not_held, held, retries_due, held_counts, retries_due_counts =
      message_aggregates(project_ids, at)
    delivery_totals, recent_failed_counts = delivery_metric_aggregates(project_ids, at)

    {
      workspace: workspace_summary(user, projects),
      delivery_health: delivery_health(
        delivery_totals: delivery_totals,
        delivering: delivering,
        pending_not_held: pending_not_held,
        held: held,
        retries_due: retries_due
      ),
      needs_attention: {
        open_circuit_endpoints: open_circuit_total,
        held_deliveries: held,
        retries_due: retries_due,
        failed_deliveries: delivery_totals[:failed]
      },
      projects: project_cards(
        user: user,
        projects: projects,
        endpoint_counts: endpoint_counts,
        active_endpoint_counts: active_endpoint_counts,
        open_circuit_counts: open_circuit_counts,
        held_counts: held_counts,
        retries_due_counts: retries_due_counts,
        recent_failed_counts: recent_failed_counts
      )
    }
  end

  def workspace_summary(user, projects)
    owned_project_count = projects.count { |project| project.billing_owner_id == user.id }

    {
      project_count: projects.size,
      owned_project_count: owned_project_count,
      shared_project_count: projects.size - owned_project_count
    }
  end

  def delivery_health(delivery_totals:, delivering:, pending_not_held:, held:, retries_due:)
    total = delivery_totals[:total]
    succeeded = delivery_totals[:succeeded]

    {
      period_label: PERIOD_LABEL,
      total: total,
      succeeded: succeeded,
      failed: delivery_totals[:failed],
      in_flight: delivering + pending_not_held,
      held: held,
      retries_due: retries_due,
      success_rate: total.positive? ? (succeeded.to_f / total * 100).round(2) : nil
    }
  end

  def project_cards(user:, projects:, endpoint_counts:, active_endpoint_counts:, open_circuit_counts:,
                    held_counts:, retries_due_counts:, recent_failed_counts:)
    projects.sort_by do |project|
      [
        open_circuit_counts.fetch(project.id, 0).positive? ? 0 : 1,
        held_counts.fetch(project.id, 0).positive? ? 0 : 1,
        retries_due_counts.fetch(project.id, 0).positive? ? 0 : 1,
        recent_failed_counts.fetch(project.id, 0).positive? ? 0 : 1,
        -project.updated_at.to_i
      ]
    end.first(MAX_PROJECTS).map do |project|
      {
        id: project.id,
        name: project.name,
        relationship: project.billing_owner_id == user.id ? 'owned' : 'shared',
        current_user_role: project.project_memberships.find { |membership| membership.user_id == user.id }&.role,
        effective_plan: project.billing_owner&.plan,
        endpoint_count: endpoint_counts.fetch(project.id, 0),
        active_endpoint_count: active_endpoint_counts.fetch(project.id, 0),
        circuit_open_endpoint_count: open_circuit_counts.fetch(project.id, 0),
        held_delivery_count: held_counts.fetch(project.id, 0),
        recent_failed_delivery_count: recent_failed_counts.fetch(project.id, 0),
        updated_at: project.updated_at.iso8601
      }
    end
  end

  def endpoint_aggregates(project_ids)
    endpoints = Endpoint.where(project_id: project_ids)

    [
      endpoints.group(:project_id).count,
      endpoints.active.not_archived.group(:project_id).count,
      endpoints.circuit_open.group(:project_id).count,
      endpoints.circuit_open.count
    ]
  end

  def message_aggregates(project_ids, at)
    messages = Message.joins(:endpoint).where(endpoints: { project_id: project_ids })

    [
      messages.delivering.count,
      messages.pending.not_held.count,
      messages.held.count,
      messages.due_for_delivery(at).count,
      messages.held.group('endpoints.project_id').count,
      messages.due_for_delivery(at).group('endpoints.project_id').count
    ]
  end

  def delivery_metric_aggregates(project_ids, at)
    metrics = DeliveryMetric.where(project_id: project_ids).where(day: period_start(at)..period_end(at))
    totals = metrics.pick(
      Arel.sql('COALESCE(SUM(attempts_count), 0)'),
      Arel.sql('COALESCE(SUM(successes_count), 0)'),
      Arel.sql('COALESCE(SUM(failures_count), 0)')
    )

    [
      { total: totals[0].to_i, succeeded: totals[1].to_i, failed: totals[2].to_i },
      metrics.group(:project_id).sum(:failures_count)
    ]
  end

  def period_start(at)
    at.to_date - (PERIOD_DAYS - 1)
  end

  def period_end(at)
    at.to_date
  end
end
