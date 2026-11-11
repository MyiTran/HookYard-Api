module Admin
  class DeliveriesQuery < ApplicationQuery
    DEFAULT_WINDOW = 7.days
    MAX_WINDOW = 90.days

    def call(scope = Message.none, **params)
      scope = by_account(scope, params[:account_id])

      MessagesQuery.call(scope, **params.merge(window(params)))
    end

    private

    def by_account(scope, account_id)
      return scope unless valid_uuid?(account_id)

      scope.joins(endpoint: :project).where(projects: { billing_owner_id: account_id })
    end

    def window(params)
      to = parsed_time(params[:to]) || Time.current
      earliest = to - MAX_WINDOW
      from = parsed_time(params[:from]) || (to - DEFAULT_WINDOW)
      from = earliest if from < earliest

      { from: from, to: to }
    end
  end
end
