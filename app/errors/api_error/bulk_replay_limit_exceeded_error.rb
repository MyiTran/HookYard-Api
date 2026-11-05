module ApiError
  class BulkReplayLimitExceededError < StandardError
    CODE = 'bulk_replay_limit_exceeded'

    attr_reader :eligible, :limit

    def initialize(message:, eligible:, limit:)
      @eligible = eligible
      @limit = limit

      super(
        message: message,
        errors: [{ field: :base, message: message }],
        status: 422,
        code: CODE
      )
    end

    def serializable_hash
      super.merge(eligible: eligible, limit: limit)
    end
  end
end
