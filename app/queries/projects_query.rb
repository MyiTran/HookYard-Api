class ProjectsQuery < ApplicationQuery
  ROLES = %w[owner maintainer].freeze

  ORDERS = {
    'created_desc' => { created_at: :desc },
    'created_asc' => { created_at: :asc },
    'name_asc' => { name: :asc }
  }.freeze

  DEFAULT_ORDER = 'created_desc'

  def call(scope = Project.none, **params)
    scope = filter(scope, :by_search, params[:search])
    scope = by_role(scope, params[:role], params[:user])

    apply_order(scope, params[:order])
  end

  private

  def by_search(scope, search)
    scope.where('projects.name ILIKE ?', "%#{search}%")
  end

  def by_role(scope, role, user)
    return scope unless ROLES.include?(role)
    return scope.none if user.nil?

    scope.where(id: user.project_memberships.where(role: role).select(:project_id))
  end

  def apply_order(scope, value)
    scope.order(ORDERS.fetch(value.to_s, ORDERS.fetch(DEFAULT_ORDER)))
  end
end
