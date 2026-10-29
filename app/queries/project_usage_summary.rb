class ProjectUsageSummary
  def initialize(projects, at: Time.current)
    @projects = projects.to_a
    @at = at
  end

  def endpoint_count_for(project)
    endpoint_counts.fetch(project.id, 0)
  end

  def deliveries_for(project)
    deliveries.fetch(project.billing_owner_id, 0)
  end

  private

  attr_reader :projects, :at

  def project_ids
    projects.map(&:id)
  end

  def account_ids
    projects.map(&:billing_owner_id).uniq
  end

  def endpoint_counts
    @endpoint_counts ||= Endpoint.where(project_id: project_ids).not_archived.group(:project_id).count
  end

  def deliveries
    @deliveries ||= UserUsagePeriod
                    .where(user_id: account_ids, period_starts_on: UserUsagePeriod.period_start_for(at))
                    .pluck(:user_id, :deliveries_count)
                    .to_h
  end
end
