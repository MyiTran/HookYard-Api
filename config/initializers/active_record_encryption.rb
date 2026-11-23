require Rails.root.join('lib/encryption_configuration')

config = Rails.application.config.active_record.encryption

if Rails.env.test?
  config.primary_key = 'hookyard-test-primary-key'
  config.deterministic_key = 'hookyard-test-deterministic-key'
  config.key_derivation_salt = 'hookyard-test-key-derivation-salt'
else
  EncryptionConfiguration.apply!(config: config)
end

if Rails.env.production?
  EncryptionConfiguration.ensure_configured!(config: config, credentials: Rails.application.credentials)
end
