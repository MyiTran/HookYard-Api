require 'rails_helper'

describe Messages::EnqueuePending, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:grace) { Constants::WEBHOOK_DELIVERY_ENQUEUE_GRACE_SECONDS.seconds }

  before { travel_to(Time.zone.local(2026, 1, 1, 12, 0, 0)) }

  def new_message(**attributes)
    create(:message, project: project, endpoint: endpoint, **attributes)
  end

  def enqueued_message_ids
    ActiveJob::Base.queue_adapter.enqueued_jobs
                       .select { |job| job[:job] == Messages::DeliverJob }
                       .map { |job| job[:args].first }
  end

  describe '.call' do
    it 'enqueues pending messages that were never retried and are past the grace period' do
      stranded = new_message
      stranded.update_columns(updated_at: (grace + 1.minute).ago)

      described_class.call

      expect(enqueued_message_ids).to contain_exactly(stranded.id)
    end

    it 'does not enqueue messages that were committed within the grace period' do
      new_message

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end

    it 'leaves messages with a scheduled retry to the retry sweep' do
      retry_waiting = new_message(next_retry_at: 1.minute.from_now)
      retry_waiting.update_columns(updated_at: (grace + 1.minute).ago)

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end

    it 'does not enqueue messages that are no longer pending' do
      delivered = new_message(status: :succeeded)
      delivered.update_columns(updated_at: (grace + 1.minute).ago)

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end
  end

  describe 'enqueue failures' do
    it 'keeps the message pending for the next recovery sweep' do
      stranded = new_message
      stranded.update_columns(updated_at: (grace + 1.minute).ago)

      allow(Messages::DeliverJob).to receive(:perform_later).and_raise(StandardError, 'redis unavailable')
      allow(Rails.logger).to receive(:error).and_call_original

      described_class.call

      expect(Rails.logger).to have_received(:error).with(/enqueue failed for message #{stranded.id}/)
      expect(stranded.reload.status).to eq('pending')
    end
  end
end
