module ApiError
  class DiagnosisCooldownError < StandardError
    CODE = 'diagnosis_rate_limited'

    attr_reader :retry_after

    def initialize(retry_after:)
      @retry_after = retry_after.to_i
      super(
        message: 'A diagnosis is already in progress or was recently completed for this endpoint',
        errors: [],
        status: 429,
        code: CODE,
        headers: { 'Retry-After' => @retry_after.to_s }
      )
    end

    def to_hash
      super.merge(retry_after: retry_after)
    end
  end
end
