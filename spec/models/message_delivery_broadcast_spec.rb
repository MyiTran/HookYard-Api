require 'rails_helper'

describe Message, type: :model do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:message) { create(:message, endpoint: endpoint, event: create(:event, project: project)) }
  let(:stream) { EndpointDeliveryChannel.broadcasting_for(endpoint) }

  before { clear_cable_messages(stream) }

  it 'broadcasts a committed status change' do
    message.update!(status: :delivering, attempt_count: 1)

    expect(cable_messages(stream).last['status']).to eq('delivering')
  end

  it 'does not broadcast a rolled back status change' do
    expect do
        described_class.transaction do
        message.update!(status: :failed)
        raise ActiveRecord::Rollback
      end
    end.not_to change { cable_messages(stream).size }
  end
end
