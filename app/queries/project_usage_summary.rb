class ProjectUsageSummary
  def initialize(projects, at: Time.current)
    @project_ids = projects.map(&:id)
    @at = at
  end

  def endpoint_count_for(project)
    endpoint_counts.fetch(project.id, 0)
  end

  def deliveries_for(project)
    deliveries.fetch(project.id, 0)
  end

  private

  attr_reader :project_ids, :at

  def endpoint_counts
    @endpoint_counts ||= Endpoint.where(project_id: project_ids).not_archived.group(:project_id).count
  end

  def deliveries
    @deliveries ||= ProjectUsagePeriod
                    .where(project_id: project_ids, period_starts_on: ProjectUsagePeriod.period_start_for(at))
                    .pluck(:project_id, :deliveries_count)
                    .to_h
  end
end
