require 'rails_helper'

RSpec.describe ActiveStorageConfiguration do
  describe '.service_name' do
    it 'defaults production storage to amazon' do
      expect(described_class.service_name(env: {})).to eq(:amazon)
    end

    it 'uses local only when explicitly configured' do
      expect(described_class.service_name(env: { 'ACTIVE_STORAGE_SERVICE' => 'local' })).to eq(:local)
    end

    it 'rejects an unsupported storage service' do
      expect { described_class.service_name(env: { 'ACTIVE_STORAGE_SERVICE' => 'disk' }) }
        .to raise_error(described_class::InvalidServiceError, /ACTIVE_STORAGE_SERVICE/)
    end
  end

  describe '.configure!' do
    let(:config) { ActiveSupport::OrderedOptions.new }
    let(:logger) { instance_spy(ActiveSupport::Logger) }

    it 'configures local storage without AWS credentials and warns about ephemeral files' do
      described_class.configure!(
        config:,
        env: { 'ACTIVE_STORAGE_SERVICE' => 'local' },
        logger:
      )

      expect(config.service).to eq(:local)
      expect(logger).to have_received(:warn).with(/ephemeral/)
    end

    it 'rejects amazon storage when AWS configuration is missing' do
      expect { described_class.configure!(config:, env: {}, logger:) }
        .to raise_error(described_class::MissingAmazonConfigurationError, /AWS_REGION/)
    end

    it 'configures amazon storage with complete AWS configuration' do
      described_class.configure!(
        config:,
        env: {
          'AWS_REGION' => 'region',
          'AWS_BUCKET' => 'bucket',
          'AWS_ACCESS_KEY_ID' => 'access-key',
          'AWS_SECRET_ACCESS_KEY' => 'secret-key'
        },
        logger:
      )

      expect(config.service).to eq(:amazon)
    end
  end
end
