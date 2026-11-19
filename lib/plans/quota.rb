module Plans
  class Quota
    MESSAGE = 'The %<plan>s plan allows at most %<limit>d deliveries per month'

    class << self
      def reserve_deliveries!(project:, quantity:, at: Time.current)
        account = project.effective_billing_owner
        raise ApiError::UnprocessableEntityError.new(message: 'Project has no billing owner') if account.nil?

        limit = Plans::Entitlements.monthly_delivery_limit(account)

        return true if UserUsagePeriod.reserve_deliveries!(user: account, quantity: quantity, limit: limit, at: at)

        raise ApiError::PlanLimitExceededError.new(
          message: format(MESSAGE, plan: account.plan, limit: limit),
          field: 'monthly_delivery_limit',
          used: UserUsagePeriod.used_deliveries(user: account, at: at),
          limit: limit,
          period_ends: UserUsagePeriod.period_ends_at(at)
        )
      end
    end
  end
end
