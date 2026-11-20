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
    scope = filter(scope, :by_circuit_state, params[:circuit_state])

    apply_order(scope, params[:order])
  end

  private

  def by_archived(scope, archived)
    return scope.not_archived if archived.blank?

    boolean_scope(scope, archived, true_scope: :archived, false_scope: :not_archived)
  end

  def by_search(scope, term)
    scope.where('endpoints.name ILIKE :term OR endpoints.url ILIKE :term', term: "%#{term}%")
  end

  def by_project(scope, project_id)
    return scope.none unless valid_uuid?(project_id)

    scope.where(project_id: project_id)
  end

  def by_active(scope, active)
    parsed = boolean_value(active)
    return scope.none if parsed.nil?

    scope.where(active: parsed)
  end

  def by_circuit_state(scope, state)
    return scope.none unless Endpoint.circuit_states.key?(state.to_s)

    scope.where(circuit_state: state.to_s)
  end

  def boolean_scope(scope, value, true_scope:, false_scope:)
    parsed = boolean_value(value)
    return scope.none if parsed.nil?

    scope.public_send(parsed ? true_scope : false_scope)
  end

  def boolean_value(value)
    case value
    when true, 'true', '1', 1 then true
    when false, 'false', '0', 0 then false
    end
  end

  def apply_order(scope, value)
    scope.order(ORDERS.fetch(value.to_s, ORDERS.fetch(DEFAULT_ORDER)))
  end
end
