module EncryptionConfiguration
  CREDENTIALS_KEY = :active_record_encryption

  SETTINGS = {
    primary_key: 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY',
    deterministic_key: 'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY',
    key_derivation_salt: 'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'
  }.freeze

  class MissingConfigurationError < StandardError; end

  def self.apply!(config:, env: ENV)
    SETTINGS.each do |setting, env_name|
      value = env[env_name]
      config.public_send(:"#{setting}=", value) if value.present?
    end
  end

  def self.ensure_configured!(config:, credentials:)
    missing = SETTINGS.keys.reject { |setting| configured?(config, credentials, setting) }
    return if missing.empty?

    raise MissingConfigurationError, "Missing Active Record Encryption configuration: #{missing.join(', ')}"
  end

  def self.configured?(config, credentials, setting)
    config.public_send(setting).present? || credentials.dig(CREDENTIALS_KEY, setting).present?
  rescue StandardError
    # Credentials are unreadable without a master key; treat that as missing configuration.
    false
  end
  private_class_method :configured?
end
