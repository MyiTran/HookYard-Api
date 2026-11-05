class ReplayCandidatesQuery < MessagesQuery
  FILTER_KEYS = %i[q message_id request_id endpoint_id event_type from to order].freeze
  FAILED_STATUS = 'failed'

  class << self
    def for_project(project)
      Message.where(event_id: Event.where(project_id: project.id).select(:id))
    end

    def count(scope = Message.none, eligible: true, as_of: nil, **params)
      new.call(scope, eligible: eligible, as_of: as_of, **params).unscope(:select).count
    end
  end

  def call(scope = Message.none, eligible: true, as_of: nil, **params)
    scope = apply_filters(base_scope(scope, as_of), filtered_params(params))

    eligible ? eligible_only(scope) : scope
  end

  private

  def base_scope(scope, as_of = nil)
    scope = scope.where(status: FAILED_STATUS)
    scope = scope.where(messages: { updated_at: ..as_of }) if as_of

    with_attempt_summary(scope).preload(:event, :endpoint, endpoint: :project)
  end

  def filtered_params(params)
    params.symbolize_keys.slice(*FILTER_KEYS)
  end

  def eligible_only(scope)
    scope.where(endpoint_id: replayable_endpoint_ids)
         .where(held_at: nil)
         .where.not(id: ReplayItem.active.select(:message_id))
  end

  def replayable_endpoint_ids
    Endpoint.replayable.select(:id)
  end
end
