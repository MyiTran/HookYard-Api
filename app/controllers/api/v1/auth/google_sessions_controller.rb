module Api
  module V1
    module Auth
      class GoogleSessionsController < Devise::SessionsController
        respond_to :json

        RATE_LIMIT = 20
        RATE_LIMIT_WINDOW = 1.minute

        rate_limit to: RATE_LIMIT,
                   within: RATE_LIMIT_WINDOW,
                   only: :create,
                   name: 'google-authentication',
                   store: Rails.application.config.x.google_authentication.rate_limit_store,
                   with: -> { render_api_error(ApiError::GoogleAuthenticationRateLimitError.new(retry_after: RATE_LIMIT_WINDOW.to_i)) }

        def create
          claims = google_token_verifier.verify(params[:credential])
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
