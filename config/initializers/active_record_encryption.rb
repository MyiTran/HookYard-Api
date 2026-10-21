require Rails.root.join('lib/encryption_configuration')

config = Rails.application.config.active_record.encryption

EncryptionConfiguration.apply!(config: config)

if Rails.env.production?
  EncryptionConfiguration.ensure_configured!(config: config, credentials: Rails.application.credentials)
end
