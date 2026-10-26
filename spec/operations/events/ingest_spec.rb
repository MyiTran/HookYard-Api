require 'rails_helper'

describe Events::Ingest, type: :operation do
  let(:project) { create(:project) }
  let!(:endpoint) { create(:endpoint, project: project) }
  let(:attributes) do
    {
      event_type: 'order.created',
      payload: { 'order_id' => SecureRandom.uuid },
      idempotency_key: SecureRandom.uuid
    }
  end

  before { endpoint.update!(event_types: [Endpoint::WILDCARD_EVENT_TYPE]) }

  describe '.call' do
    it 'persists the event with its messages and enqueues delivery' do
      expect { @result = described_class.call(project: project, attributes: attributes) }
        .to have_enqueued_job(Messages::DeliverJob)

      expect(@result.created).to be(true)
      expect(@result.event).to be_persisted
      expect(@result.messages_count).to eq(1)
    end

    it 'keeps the committed event and messages waiting when enqueueing fails' do
      allow(Messages::DeliverJob).to receive(:perform_later).and_raise(StandardError, 'redis unavailable')
      allow(Rails.logger).to receive(:error).and_call_original

      result = described_class.call(project: project, attributes: attributes)

      expect(result.event.reload).to be_persisted
      expect(result.event.messages.pending.count).to eq(1)
      expect(Rails.logger).to have_received(:error).with(/enqueue failed for message/)
    end
  end
end
