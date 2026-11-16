class IngestRejectionsQuery < ApplicationQuery
  ORDERS = {
    'created_desc' => { created_at: :desc, id: :desc },
    'created_asc' => { created_at: :asc, id: :asc }
  }.freeze

  DEFAULT_ORDER = 'created_desc'

  def call(scope = IngestRejection.none, **params)
    scope = scope.preload(:project, :endpoint)

    scope = filter(scope, :by_project, params[:project_id])
    scope = filter(scope, :by_reason, params[:reason])
    scope = filter(scope, :by_event_type, params[:event_type])
    scope = filter(scope, :by_from, params[:from])
    scope = filter(scope, :by_to, params[:to])

    apply_order(scope, params[:order])
  end

  private

  def by_project(scope, project_id)
    return scope unless valid_uuid?(project_id)

    scope.where(project_id: project_id)
  end

  def by_reason(scope, reason)
    return scope unless IngestRejection::REASONS.include?(reason.to_s)

    scope.where(reason: reason.to_s)
  end

  def by_event_type(scope, event_type)
    scope.where(event_type: event_type.to_s)
  end

  def by_from(scope, value)
    time = parsed_time(value)
    return scope if time.nil?

    scope.where('ingest_rejections.created_at >= ?', time)
  end

  def by_to(scope, value)
    time = parsed_time(value)
    return scope if time.nil?

    scope.where('ingest_rejections.created_at <= ?', time)
  end

  def apply_order(scope, value)
    scope.order(ORDERS.fetch(value.to_s, ORDERS.fetch(DEFAULT_ORDER)))
  end
end
