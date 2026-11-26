require 'googleauth/id_tokens'

module Authentication
  class GoogleTokenVerifier
    ISSUERS = %w[accounts.google.com https://accounts.google.com].freeze

    def verify(credential)
      raise ApiError::GoogleAuthenticationError.new(status: 400, code: 'google_credential_missing') if credential.blank?

      claims = Google::Auth::IDTokens.verify_oidc(credential, aud: client_id, iss: ISSUERS)
      validate_claims!(claims)
      claims
    rescue ApiError::GoogleAuthenticationError
      raise
    rescue StandardError
      raise ApiError::GoogleAuthenticationError.new
    end

    private

    def client_id
      ENV.fetch('GOOGLE_CLIENT_ID')
    rescue KeyError
      raise ApiError::GoogleAuthenticationError.new(status: 500, code: 'google_authentication_unavailable')
    end

    def validate_claims!(claims)
      raise ApiError::GoogleAuthenticationError.new if claims['sub'].blank? || claims['email'].blank?
      raise ApiError::GoogleAuthenticationError.new(status: 403, code: 'google_email_unverified') unless claims['email_verified'] == true
    end
  end
end
