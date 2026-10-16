require 'rails_helper'

describe Endpoints::Archive, type: :operation do
  let(:endpoint) { create(:endpoint) }

  describe '.call' do
    it 'marks the endpoint archived without deleting it' do
      described_class.call(endpoint: endpoint)

      expect(endpoint.reload).to be_archived
      expect(Endpoint.exists?(endpoint.id)).to be(true)
    end

    it 'keeps the original archived_at when called again' do
      described_class.call(endpoint: endpoint)
      archived_at = endpoint.reload.archived_at

      described_class.call(endpoint: endpoint)

      expect(endpoint.reload.archived_at).to eq(archived_at)
    end

    it 'preserves subscription data and signing-secret history' do
      endpoint = create(:endpoint, event_types: %w[order.created])
      endpoint.rotate_signing_secret!
      current_version = endpoint.signing_secret_version

      described_class.call(endpoint: endpoint)

      expect(endpoint.reload.event_types).to eq(%w[order.created])
      expect(endpoint.endpoint_signing_secrets.count).to eq(2)
      expect(endpoint.signing_secret_version).to eq(current_version)
    end
  end
end
