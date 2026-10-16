class EndpointsQuery < ApplicationQuery
  ORDERS = {
    'created_desc' => { created_at: :desc, id: :desc },
    'created_asc' => { created_at: :asc, id: :asc },
    'name_asc' => { name: :asc, id: :asc }
  }.freeze

  DEFAULT_ORDER = 'created_desc'

  def call(scope = Endpoint.none, **params)
    scope = by_archived(scope, params[:archived])
    scope = filter(scope, :by_search, params[:q])
    scope = filter(scope, :by_project, params[:project_id])
    scope = filter(scope, :by_active, params[:active])

    apply_order(scope, params[:order])
  end

  private

  def by_archived(scope, archived)
    ActiveModel::Type::Boolean.new.cast(archived) ? scope.archived : scope.not_archived
  end

  def by_search(scope, term)
    scope.where('endpoints.name ILIKE :term OR endpoints.url ILIKE :term', term: "%#{term}%")
  end

  def by_project(scope, project_id)
    scope.where(project_id: project_id)
  end

  def by_active(scope, active)
    scope.where(active: ActiveModel::Type::Boolean.new.cast(active))
  end

  def apply_order(scope, value)
    scope.order(ORDERS.fetch(value.to_s, ORDERS.fetch(DEFAULT_ORDER)))
  end
end
