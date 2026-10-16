require 'rails_helper'

describe Endpoints::Create, type: :operation do
  let(:project) { create(:project, :with_owner) }

  describe '.call' do
    it 'creates an endpoint scoped to the project with an initial signing secret' do
      endpoint = described_class.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' })

      expect(endpoint).to be_persisted
      expect(endpoint.project).to eq(project)
      expect(endpoint.current_signing_secret.version).to eq(1)
      expect(endpoint.current_signing_secret.secret).to be_present
      expect(endpoint.current_signing_secret).not_to be_retired
    end

    it 'persists the requested event type subscriptions' do
      endpoint = described_class.call(
        project: project,
        attributes: { name: 'Billing', url: 'https://example.com/hooks', event_types: %w[order.created order.updated] }
      )

      expect(endpoint.event_types).to contain_exactly('order.created', 'order.updated')
    end

    it 'raises when the attributes are invalid' do
      expect { described_class.call(project: project, attributes: { name: '', url: '' }) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(project.endpoints.count).to eq(0)
    end
  end
end
