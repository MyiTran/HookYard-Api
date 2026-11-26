module Authentication
  class GoogleSignIn < ApplicationOperation
    def call(claims:)
      User.transaction do
        identity = UserIdentity.lock.find_by(provider: UserIdentity::GOOGLE_PROVIDER, uid: claims.fetch('sub'))
        return identity.user if identity

        user = User.find_by(email: normalized_email(claims))
        user = create_user!(claims) if user.nil?
        link_identity!(user, claims)
        user
      end
    rescue ActiveRecord::RecordNotUnique
      identity = UserIdentity.find_by(provider: UserIdentity::GOOGLE_PROVIDER, uid: claims.fetch('sub'))
      return identity.user if identity

      raise ApiError::GoogleAuthenticationError.new(status: 409, code: 'account_link_required')
    end

    private

    def normalized_email(claims)
      claims.fetch('email').strip.downcase
    end

    def create_user!(claims)
      first_name, last_name = names_for(claims)
      password = SecureRandom.base64(48)
      user = User.new(
        email: normalized_email(claims), first_name:, last_name:, password:, password_confirmation: password,
        confirmed_at: Time.current
      )
      user.skip_confirmation_notification!
      user.save!
      user.add_role(:support)
      user
    end

    def link_identity!(user, claims)
      raise ApiError::GoogleAuthenticationError.new(status: 409, code: 'account_link_required') unless user.confirmed?

      user.user_identities.create!(
        provider: UserIdentity::GOOGLE_PROVIDER,
        uid: claims.fetch('sub'),
        email_at_provider: normalized_email(claims)
      )
    end

    def names_for(claims)
      [claims['given_name'].presence || 'Google', claims['family_name'].presence || 'User']
    end
  end
end
