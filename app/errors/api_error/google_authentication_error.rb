module ApiError
  class GoogleAuthenticationError < StandardError
    def initialize(status: 401, code: 'google_authentication_failed')
      super(message: 'Google authentication could not be verified', errors: [], status:, code:)
    end
  end
end
