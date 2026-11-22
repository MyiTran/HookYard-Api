module Api
  module V1
    module Auth
      class GoogleSessionsController < Devise::SessionsController
        respond_to :json

        rate_limit to: 20,
                   within: 1.minute,
                   only: :create,
                   name: 'google-authentication',
                   store: Rails.application.config.x.google_authentication.rate_limit_store,
                   with: -> { render_api_error(ApiError::GoogleAuthenticationError.new(status: 429, code: 'google_authentication_rate_limited')) }

        def create
          claims = google_token_verifier.verify(params.require(:credential))
          user = Authentication::GoogleSignIn.call(claims:)
          sign_in(:user, user)
          render_resource(user)
        end

        private

        def google_token_verifier
          Authentication::GoogleTokenVerifier.new
        end
      end
    end
  end
end
