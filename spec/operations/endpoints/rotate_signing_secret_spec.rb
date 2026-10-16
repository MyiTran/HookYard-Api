require 'rails_helper'

describe Endpoints::RotateSigningSecret, type: :operation do
  let(:endpoint) { create(:endpoint) }

  describe '.call' do
    it 'creates a new secret version and returns it' do
      secret = described_class.call(endpoint: endpoint)

      expect(secret.version).to eq(2)
      expect(secret.secret).to be_present
      expect(endpoint.endpoint_signing_secrets.order(:version).pluck(:version)).to eq([1, 2])
    end

    it 'keeps the retired previous version persisted as history' do
      previous = endpoint.current_signing_secret
      previous_secret = previous.secret

      described_class.call(endpoint: endpoint)

      expect(endpoint.current_signing_secret.version).to eq(2)
      expect(previous.reload).to be_retired
      expect(endpoint.endpoint_signing_secrets.order(:version).first.secret).to eq(previous_secret)
    end

    it 'retires the previous version so only the new one is current' do
      previous = endpoint.current_signing_secret

      described_class.call(endpoint: endpoint)

      expect(previous.reload).to be_retired
      expect(endpoint.endpoint_signing_secrets.current.pluck(:version)).to eq([2])
    end

    it 'keeps exactly one current version across repeated rotations' do
      described_class.call(endpoint: endpoint)
      described_class.call(endpoint: endpoint)

      expect(endpoint.endpoint_signing_secrets.count).to eq(3)
      expect(endpoint.endpoint_signing_secrets.current.count).to eq(1)
    end
  end
end
