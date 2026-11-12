module ApiError
  class QueueCapacityExceededError < StandardError
    CODE = 'queue_capacity_exceeded'
    RETRY_AFTER_SECONDS = 30

    def initialize(message: nil)
      super(
        message: message || 'The endpoint queue can not accept more events',
        errors: [],
        status: 429,
        code: CODE,
        headers: { 'Retry-After' => RETRY_AFTER_SECONDS.to_s }
      )
    end
  end
end
