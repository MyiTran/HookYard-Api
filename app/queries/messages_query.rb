class MessagesQuery < ApplicationQuery
  include MessageAttemptSummary

  UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  ORDERS = {
    'created_desc' => { created_at: :desc, id: :desc },
    'created_asc' => { created_at: :asc, id: :asc }
  }.freeze

  DEFAULT_ORDER = 'created_desc'

  def call(scope = Message.none, **params)
    scope = with_attempt_summary(scope).preload(:event, :endpoint, endpoint: :project)

    scope = filter(scope, :by_search, params[:q])
    scope = filter(scope, :by_project, params[:project_id])
    scope = filter(scope, :by_endpoint, params[:endpoint_id])
    scope = filter(scope, :by_status, params[:status])
    scope = filter(scope, :by_event_type, params[:event_type])
    scope = filter(scope, :by_from, params[:from])
    scope = filter(scope, :by_to, params[:to])

    apply_order(scope, params[:order])
  end

  private

  def by_search(scope, term)
    normalized = term.to_s.strip.delete_prefix('msg_')
    return scope if normalized.blank?

    pattern = "%#{Message.sanitize_sql_like(normalized)}%"

    scope.where(
      'messages.id::text ILIKE :pattern OR EXISTS (' \
      'SELECT 1 FROM delivery_attempts ' \
      'WHERE delivery_attempts.message_id = messages.id AND delivery_attempts.request_id ILIKE :pattern)',
      pattern: pattern
    )
  end

  def by_project(scope, project_id)
    return scope unless valid_uuid?(project_id)

    scope.where(event_id: Event.where(project_id: project_id).select(:id))
  end

  def by_endpoint(scope, endpoint_id)
    return scope unless valid_uuid?(endpoint_id)

    scope.where(endpoint_id: endpoint_id)
  end

  def by_status(scope, status)
    return scope unless Message.statuses.key?(status.to_s)

    scope.where(status: status.to_s)
  end

  def by_event_type(scope, event_type)
    scope.where(event_id: Event.where(event_type: event_type).select(:id))
  end

  def by_from(scope, value)
    time = parsed_time(value)
    return scope if time.nil?

    scope.where('messages.created_at >= ?', time)
  end

  def by_to(scope, value)
    time = parsed_time(value)
    return scope if time.nil?

    scope.where('messages.created_at <= ?', time)
  end

  def apply_order(scope, value)
    scope.order(ORDERS.fetch(value.to_s, ORDERS.fetch(DEFAULT_ORDER)))
  end

  def valid_uuid?(value)
    value.to_s.match?(UUID_FORMAT)
  end

  def parsed_time(value)
    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
