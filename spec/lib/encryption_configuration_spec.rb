require 'rails_helper'

describe EncryptionConfiguration do
  describe '.apply!' do
    it 'overrides configured keys with present ENV values' do
      config = ActiveSupport::OrderedOptions.new
      config.primary_key = 'from-credentials'

      described_class.apply!(config: config, env: { 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => 'from-env' })

      expect(config.primary_key).to eq('from-env')
    end

    it 'keeps configured keys when ENV values are blank' do
      config = ActiveSupport::OrderedOptions.new
      config.primary_key = 'from-credentials'

      described_class.apply!(config: config, env: { 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => ' ' })

      expect(config.primary_key).to eq('from-credentials')
    end
  end

  describe '.ensure_configured!' do
    it 'raises when no key source is configured' do
      expect { described_class.ensure_configured!(config: ActiveSupport::OrderedOptions.new, credentials: {}) }
        .to raise_error(described_class::MissingConfigurationError, /primary_key/)
    end

    it 'does not raise when the keys come from application config' do
      config = ActiveSupport::OrderedOptions.new
      config.primary_key = 'primary'
      config.deterministic_key = 'deterministic'
      config.key_derivation_salt = 'salt'

      expect { described_class.ensure_configured!(config: config, credentials: {}) }.not_to raise_error
    end

    it 'does not raise when the keys come from credentials' do
      credentials = {
        active_record_encryption: {
          primary_key: 'primary',
          deterministic_key: 'deterministic',
          key_derivation_salt: 'salt'
        }
      }

      expect { described_class.ensure_configured!(config: ActiveSupport::OrderedOptions.new, credentials: credentials) }
        .not_to raise_error
    end
  end
end
