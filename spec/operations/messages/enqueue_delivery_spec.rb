require 'rails_helper'

describe Messages::EnqueueDelivery, type: :operation do
  include ActiveJob::TestHelper

  describe '.call' do
    let(:event) { create(:event) }
    let(:message) { create(:message, event: event, endpoint: create(:endpoint, project: event.project)) }
    let(:other_message) { create(:message, event: event, endpoint: create(:endpoint, project: event.project)) }

    before { clear_enqueued_jobs }

    it 'enqueues a delivery job for every message id' do
      expect { described_class.call(message_ids: [message.id, other_message.id]) }
        .to have_enqueued_job(Messages::DeliverJob).with(message.id)
        .and have_enqueued_job(Messages::DeliverJob).with(other_message.id)
    end

    it 'enqueues nothing when there are no message ids' do
      expect { described_class.call(message_ids: []) }.not_to have_enqueued_job(Messages::DeliverJob)
    end

    context 'when the job queue rejects a message' do
      before do
        allow(Rails.logger).to receive(:error)
        allow(Messages::DeliverJob).to receive(:perform_later).and_call_original
        allow(Messages::DeliverJob).to receive(:perform_later).with(message.id).and_raise(RuntimeError, 'redis unavailable')
      end

      it 'logs the failed enqueue instead of raising' do
        expect { described_class.call(message_ids: [message.id]) }.not_to raise_error

        expect(Rails.logger).to have_received(:error).with(/Webhook delivery enqueue failed for message #{message.id}/)
      end

      it 'still enqueues the remaining messages' do
        described_class.call(message_ids: [message.id, other_message.id])

        expect(Messages::DeliverJob).to have_received(:perform_later).with(other_message.id)
      end
    end
  end
end
