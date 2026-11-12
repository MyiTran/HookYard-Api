class MessagesQuery < ApplicationQuery
  include MessageAttemptSummary

  LAST_RESPONSE_STATUS_ALIAS = 'delivery_attempt_stats.last_response_status'.freeze
  LAST_ERROR_TYPE_ALIAS = 'delivery_attempt_stats.last_error_type'.freeze

  ORDERS = {
    'created_desc' => { created_at: :desc, id: :desc },
    'created_asc' => { created_at: :asc, id: :asc }
  }.freeze

  DEFAULT_ORDER = 'created_desc'

  def call(scope = Message.none, **params)
    scope = with_attempt_summary(scope).preload(
      :event, :endpoint, :active_replay_item, :latest_replay_item, endpoint: :project
    )

    apply_filters(scope, params)
  end

  private

  def apply_filters(scope, params)
    scope = filter(scope, :by_search, params[:q])
    scope = filter(scope, :by_message_id, params[:message_id])
    scope = filter(scope, :by_request_id, params[:request_id])
    scope = filter(scope, :by_project, params[:project_id])
    scope = filter(scope, :by_endpoint, params[:endpoint_id])
    scope = filter(scope, :by_status, params[:status])
    scope = filter(scope, :by_failure_category, params[:failure_category])
    scope = filter(scope, :by_delivery_state, params[:delivery_state])
    scope = filter(scope, :by_event_type, params[:event_type])
    scope = filter(scope, :by_from, params[:from])
    scope = filter(scope, :by_to, params[:to])

    apply_order(scope, params[:order])
  end

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

  def by_message_id(scope, value)
    normalized = identifier_value(value, 'msg_')
    return scope.none unless normalized.match?(UUID_FORMAT)

    scope.where(id: normalized)
  end

  def by_request_id(scope, value)
    identifiers = identifier_candidates(value, 'req_')
    return scope if identifiers.empty?

    scope.where(id: DeliveryAttempt.where(request_id: identifiers).select(:message_id))
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

  def by_failure_category(scope, category)
    condition = failure_category_condition(category.to_s)
    return scope if condition.nil?

    scope.where(condition).where(failed_delivery_condition)
  end

  def failed_delivery_condition
    success_statuses = DeliveryAttempt::RESPONSE_SUCCESS_STATUSES

    ActiveRecord::Base.sanitize_sql_array(
      ["#{LAST_RESPONSE_STATUS_ALIAS} IS NULL OR #{LAST_RESPONSE_STATUS_ALIAS} NOT BETWEEN ? AND ?",
       success_statuses.first, success_statuses.last]
    )
  end

  def failure_category_condition(category)
    case category
    when Webhooks::FailureCategory::DESTINATION_REJECTED
      last_error_type_in(Webhooks::FailureCategory::DESTINATION_REJECTION_TYPES)
    when Webhooks::FailureCategory::INTERRUPTED
      last_error_type_in(Webhooks::FailureCategory::INTERRUPTED_ERROR_TYPES)
    when Webhooks::FailureCategory::TIMEOUT
      last_error_type_in(Webhooks::FailureCategory::TIMEOUT_ERROR_TYPES)
    when Webhooks::FailureCategory::NETWORK
      ActiveRecord::Base.sanitize_sql_array(
        ["#{LAST_ERROR_TYPE_ALIAS} IS NOT NULL AND #{LAST_ERROR_TYPE_ALIAS} NOT IN (?)", classified_error_types]
      )
    when Webhooks::FailureCategory::HTTP_ERROR
      "#{LAST_RESPONSE_STATUS_ALIAS} IS NOT NULL AND #{LAST_ERROR_TYPE_ALIAS} IS NULL"
    end
  end

  def last_error_type_in(error_types)
    ActiveRecord::Base.sanitize_sql_array(["#{LAST_ERROR_TYPE_ALIAS} IN (?)", error_types])
  end

  def classified_error_types
    Webhooks::FailureCategory::DESTINATION_REJECTION_TYPES +
      Webhooks::FailureCategory::INTERRUPTED_ERROR_TYPES +
      Webhooks::FailureCategory::TIMEOUT_ERROR_TYPES
  end

  def by_delivery_state(scope, state)
    delivery_state_scope = Message.delivery_state_scope(state)
    return scope.merge(delivery_state_scope) if delivery_state_scope

    raise ApiError::UnprocessableEntityError.new(
      message: 'Unsupported delivery state',
      errors: [{ field: 'delivery_state', message: 'is not supported' }]
    )
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

  def identifier_value(value, prefix)
    value.to_s.strip.delete_prefix(prefix)
  end

  def identifier_candidates(value, prefix)
    raw = value.to_s.strip
    return [] if raw.blank?

    [raw, "#{prefix}#{identifier_value(raw, prefix)}"].uniq
  end
end
