# Active Record Encryption requires keys. Derive them from the existing
# secret_key_base instead of introducing new credentials, so encrypted
# attributes work without regenerating config/credentials.yml.enc.
key_generator = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base, iterations: 1000)

Rails.application.config.active_record.encryption.primary_key =
  key_generator.generate_key('active_record_encryption primary key')
Rails.application.config.active_record.encryption.deterministic_key =
  key_generator.generate_key('active_record_encryption deterministic key')
Rails.application.config.active_record.encryption.key_derivation_salt =
  key_generator.generate_key('active_record_encryption key derivation salt')
