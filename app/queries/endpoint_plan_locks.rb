class EndpointPlanLocks
  def initialize(projects)
    @projects = projects.index_by(&:id)
    @locked_ids = {}
  end

  def locked?(endpoint)
    locked_ids_for(endpoint.project_id).include?(endpoint.id)
  end

  private

  attr_reader :projects, :locked_ids

  def locked_ids_for(project_id)
    locked_ids.fetch(project_id) { locked_ids[project_id] = plan_locked_ids(project_id) }
  end

  def plan_locked_ids(project_id)
    project = projects[project_id]

    project ? project.plan_locked_endpoint_ids : []
  end
end
