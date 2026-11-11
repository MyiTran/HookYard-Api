require 'rails_helper'

describe Admin::EndpointSummaryQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  describe '.call' do
    it 'summarizes total, recent and held deliveries for the endpoint' do
      create(:message, project: project, endpoint: endpoint)
      create(:message, project: project, endpoint: endpoint, created_at: 8.days.ago)
      held_message = create(:message, project: project, endpoint: endpoint)
      held_message.hold!(reason: 'endpoint_circuit_open')

      other_project = create(:project)
      other_endpoint = create(:endpoint, project: other_project)
      create(:message, project: other_project, endpoint: other_endpoint)

      summary = described_class.call(endpoint)

      expect(summary).to eq(
        total: 3,
        recent: 2,
        held: 1
      )
    end
  end
end
