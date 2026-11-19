module Admin
  class DeliveriesQuery < ApplicationQuery
    DEFAULT_WINDOW = 7.days
    MAX_WINDOW = 90.days
    FAILURE_CATEGORIES = [
      Webhooks::FailureCategory::DESTINATION_REJECTED,
      Webhooks::FailureCategory::INTERRUPTED,
      Webhooks::FailureCategory::TIMEOUT,
      Webhooks::FailureCategory::NETWORK,
      Webhooks::FailureCategory::HTTP_ERROR
    ].freeze

    def call(scope = Message.none, **params)
      return scope.none if invalid_filters?(params)

      scope = by_account(scope, params[:account_id])

      MessagesQuery.call(scope, preload_replay_items: false, **params.merge(window(params)))
    end

    private

    def by_account(scope, account_id)
      return scope if account_id.blank?

      scope.joins(endpoint: :project).where(projects: { billing_owner_id: account_id })
    end

    def invalid_filters?(params)
      invalid_uuid_filter?(params, :account_id) ||
        invalid_uuid_filter?(params, :project_id) ||
        invalid_uuid_filter?(params, :endpoint_id) ||
        invalid_status?(params[:status]) ||
        invalid_failure_category?(params[:failure_category]) ||
        invalid_time?(params[:from]) ||
        invalid_time?(params[:to])
    end

    def invalid_uuid_filter?(params, key)
      value = params[key]
      value.present? && !valid_uuid?(value)
    end

    def invalid_status?(status)
      status.present? && !Message.statuses.key?(status.to_s)
    end

    def invalid_failure_category?(category)
      category.present? && !FAILURE_CATEGORIES.include?(category.to_s)
    end

    def invalid_time?(value)
      value.present? && parsed_time(value).nil?
    end

    def window(params)
      return {} if params[:from].blank? && params[:to].blank?

      to = parsed_time(params[:to]) || Time.current
      earliest = to - MAX_WINDOW
      from = parsed_time(params[:from]) || (to - DEFAULT_WINDOW)
      from = earliest if from < earliest

      { from: from, to: to }
    end
  end
end
