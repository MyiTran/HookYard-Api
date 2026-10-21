require 'rails_helper'

describe EndpointSigningSecret, type: :model do
  describe 'encryption' do
    let(:endpoint) { create(:endpoint) }

    it 'reads the secret back after storing it encrypted' do
      record = endpoint.endpoint_signing_secrets.create!(version: 99, secret: 'whsec_round_trip', retired_at: Time.current)

      expect(record.ciphertext_for(:secret)).not_to include('whsec_round_trip')
      expect(described_class.find(record.id).secret).to eq('whsec_round_trip')
    end

    it 'uses the isolated test keys instead of keys derived from secret_key_base' do
      expect(ActiveRecord::Encryption.config.primary_key).to eq('hookyard-test-primary-key')
      expect(ActiveRecord::Encryption.config.deterministic_key).to eq('hookyard-test-deterministic-key')
      expect(ActiveRecord::Encryption.config.key_derivation_salt).to eq('hookyard-test-key-derivation-salt')
    end
  end
end
