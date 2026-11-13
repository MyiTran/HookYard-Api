require 'rails_helper'

describe ProjectRealtimeChannel, type: :channel do
  let(:project) { create(:project, :with_owner) }
  let(:owner) { project.owner }
  let(:outsider) { create(:user) }

  describe 'subscription' do
    context 'when the connection user is the project owner' do
      before { stub_connection(current_user: owner) }

      it 'streams from the project stream' do
        subscribe project_id: project.id

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from(described_class.stream_name(project.id))
      end
    end

    context 'when the connection user is a project maintainer' do
      let(:member) { create(:project_membership, project: project, role: :maintainer).user }

      before { stub_connection(current_user: member) }

      it 'streams from the project stream' do
        subscribe project_id: project.id

        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_from(described_class.stream_name(project.id))
      end
    end

    context 'when the connection user is not a project member' do
      before { stub_connection(current_user: outsider) }

      it 'rejects the subscription' do
        subscribe project_id: project.id

        expect(subscription).to be_rejected
      end
    end
  end

  describe '.broadcast' do
    let(:stream) { described_class.stream_name(project.id) }

    before { clear_cable_messages(stream) }

    it 'publishes only whitelisted safe keys' do
      described_class.broadcast(
        project.id,
        type: 'message.changed',
        project_id: project.id,
        endpoint_id: SecureRandom.uuid,
        message_id: SecureRandom.uuid,
        status: 'succeeded',
        delivery_state: 'terminal',
        occurred_at: Time.current.iso8601,
        body: 'response body leak',
        header: 'authorization leak',
        secret: 'signing secret leak'
      )

      message = cable_messages(stream).sole

      expect(message.keys).to contain_exactly(
        'type', 'project_id', 'endpoint_id', 'message_id', 'status', 'delivery_state', 'occurred_at'
      )
      expect(message).not_to include('body', 'header', 'secret')
    end
  end

  describe '.message_changed' do
    let(:message) { create(:message, project: project) }
    let(:stream) { described_class.stream_name(project.id) }

    before { clear_cable_messages(stream) }

    it 'publishes compact delivery metadata' do
      described_class.message_changed(message)

      payload = cable_messages(stream).sole

      expect(payload).to include(
        'type' => 'message.changed',
        'project_id' => project.id,
        'endpoint_id' => message.endpoint_id,
        'message_id' => message.id,
        'status' => 'pending',
        'delivery_state' => 'queued'
      )
      expect(payload['occurred_at']).to be_present
    end
  end
end
