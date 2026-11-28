require 'rails_helper'

describe EndpointDeliveryChannel, type: :channel do
  let(:owner) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:message) { create(:message, endpoint: endpoint, event: create(:event, project: project)) }
  let(:stream) { described_class.broadcasting_for(endpoint) }

  before { clear_cable_messages(stream) }

  describe 'subscription' do
    it 'confirms a project member' do
      stub_connection(current_user: owner)

      subscribe(endpoint_id: endpoint.id)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(endpoint)
    end

    it 'rejects a user without endpoint access' do
      stub_connection(current_user: outsider)

      subscribe(endpoint_id: endpoint.id)

      expect(subscription).to be_rejected
    end

    it 'confirms a system administrator' do
      admin = create(:user)
      admin.add_role(:admin)
      stub_connection(current_user: admin)

      subscribe(endpoint_id: endpoint.id)

      expect(subscription).to be_confirmed
    end
  end

  describe '.broadcast_message' do
    it 'broadcasts only the delivery fields' do
      attempt = create(:delivery_attempt, message: message, response_status: 200, duration_ms: 193)
      message.update!(status: :succeeded, attempt_count: 1)

      payload = cable_messages(stream).last

      expect(payload).to include(
        'type' => 'delivery.updated', 'endpoint_id' => endpoint.id, 'message_id' => message.id,
        'event_type' => message.event.event_type, 'status' => 'succeeded', 'attempt_count' => 1,
        'latest_attempt_status' => 'succeeded', 'response_status' => 200, 'duration_ms' => 193
      )
      expect(payload.keys).not_to include('request_body', 'response_body', 'request_headers', 'secret', 'payload')
      expect(attempt).to be_persisted
    end

    it 'does not raise when broadcasting fails' do
      allow(described_class).to receive(:broadcast_to).and_raise(StandardError, 'unavailable')

      expect { described_class.broadcast_message(message) }.not_to raise_error
    end
  end
end
