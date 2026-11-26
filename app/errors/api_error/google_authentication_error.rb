module ApiError
  class GoogleAuthenticationError < StandardError
    def initialize(status: 401, code: 'google_authentication_failed', headers: {})
      super(message: 'Google authentication could not be verified', errors: [], status:, code:, headers:)
    end
  end
end
