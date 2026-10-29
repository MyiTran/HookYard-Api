module ApiError
  class PlanLimitExceededError < StandardError
    CODE = 'plan_limit_exceeded'

    attr_reader :used, :limit, :period_ends

    def initialize(message:, field:, used:, limit:, period_ends: nil)
      @used = used
      @limit = limit
      @period_ends = period_ends
      super(
        message: message,
        errors: [{ field: field, message: message }],
        status: 402,
        code: CODE
      )
    end

    def serializable_hash
      {
        error: CODE,
        message: message,
        status: status,
        used: used,
        limit: limit,
        period_ends: period_ends&.utc&.iso8601,
        errors: errors
      }.compact
    end
  end
end
