require 'rails_helper'

describe Messages::ReconcileQueue, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  def queued_message(queued_at: Time.current)
    create(:message, project: project, endpoint: endpoint).tap do |message|
      message.update_columns(queued_at: queued_at, created_at: queued_at)
    end
  end

  describe '.call' do
    it 'rebuilds the counter from the messages that own a queue slot' do
      2.times { queued_message }
      endpoint.update!(queued_message_count: 0)

      described_class.call(endpoint: endpoint)

      expect(endpoint.reload.queued_message_count).to eq(2)
    end

    it 'releases the queue slot of a terminal message that still held one' do
      delivered = queued_message
      delivered.update_columns(status: 'succeeded', terminal_at: Time.current)
      endpoint.update!(queued_message_count: 1)

      described_class.call(endpoint: endpoint)

      expect(delivered.reload.queued_at).to be_nil
      expect(endpoint.reload.queued_message_count).to eq(0)
    end

    it 'keeps pending, delivering and held messages counted' do
      held = queued_message
      held.update_columns(held_at: Time.current, hold_reason: 'endpoint_circuit_open')
      delivering = queued_message
      delivering.update_columns(
        status: 'delivering', attempt_count: 1, delivery_lease_expires_at: 30.seconds.from_now
      )

      described_class.call(endpoint: endpoint)

      expect(endpoint.reload.queued_message_count).to eq(2)
    end

    it 'is idempotent across repeated runs' do
      queued_message
      failed = queued_message
      failed.update_columns(status: 'failed', terminal_at: Time.current)
      endpoint.update!(queued_message_count: 7)

      described_class.call(endpoint: endpoint)
      described_class.call(endpoint: endpoint)

      expect(endpoint.reload.queued_message_count).to eq(1)
    end

    it 'ignores messages of other endpoints' do
      other_endpoint = create(:endpoint, project: project)
      create(:message, project: project, endpoint: other_endpoint)
        .update_columns(queued_at: Time.current)
      other_endpoint.update!(queued_message_count: 1)
      endpoint.update!(queued_message_count: 4)

      described_class.call(endpoint: endpoint)

      expect(endpoint.reload.queued_message_count).to eq(0)
      expect(other_endpoint.reload.queued_message_count).to eq(1)
    end
  end
end
