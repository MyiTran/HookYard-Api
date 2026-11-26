module ApiError
  class GoogleAuthenticationRateLimitError < GoogleAuthenticationError
    attr_reader :retry_after

    def initialize(retry_after:)
      @retry_after = retry_after.to_i
      super(
        status: 429,
        code: 'google_authentication_rate_limited',
        headers: { 'Retry-After' => @retry_after.to_s }
      )
    end

    def to_hash
      super.merge(retry_after: retry_after)
    end
  end
end
