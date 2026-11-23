module Users
  class BootstrapAdmin < ApplicationOperation
    class MissingCredentialsError < StandardError; end
    class ExistingUserConflictError < StandardError; end
    class ExistingAdministratorConflictError < StandardError; end

    def call(email:, password:, override: false)
      normalized_email = email.to_s.strip.downcase
      normalized_password = password.to_s
      raise MissingCredentialsError, 'BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD must be present' if normalized_email.blank? || normalized_password.blank?

      User.transaction do
        existing_user = User.lock.find_by('LOWER(email) = ?', normalized_email)
        return existing_user if existing_user&.admin?

        existing_admin = User.with_role(:admin).lock.exists?
        raise ExistingAdministratorConflictError, 'an administrator already exists; set BOOTSTRAP_ADMIN_OVERRIDE=1 to continue' if existing_admin && !override
        raise ExistingUserConflictError, 'the bootstrap email already belongs to a non-administrator; set BOOTSTRAP_ADMIN_OVERRIDE=1 to elevate it' if existing_user.present? && !override

        user = existing_user || create_user(normalized_email, normalized_password)
        user.add_role(:admin) unless user.admin?
        user
      end
    end

    private

    def create_user(email, password)
      User.create!(
        email:,
        password:,
        password_confirmation: password,
        first_name: 'Bootstrap',
        last_name: 'Administrator',
        confirmed_at: Time.current
      )
    end
  end
end
