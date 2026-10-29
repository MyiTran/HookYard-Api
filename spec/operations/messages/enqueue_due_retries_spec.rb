require 'rails_helper'

describe Messages::EnqueueDueRetries, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

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
    it 'enqueues pending messages with a retry time that has passed' do
      due = new_message(next_retry_at: 1.minute.ago)

      described_class.call

      expect(enqueued_message_ids).to contain_exactly(due.id)
    end

    it 'does not enqueue pending messages that were never retried' do
      new_message

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end

    it 'does not enqueue messages whose retry is still in the future' do
      new_message(next_retry_at: 1.minute.from_now)

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end

    it 'does not enqueue delivering or terminal messages' do
      new_message(status: :delivering, next_retry_at: 1.minute.ago)
      new_message(status: :succeeded, next_retry_at: 1.minute.ago)
      new_message(status: :failed, next_retry_at: 1.minute.ago)

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end
  end

  describe 'enqueue failures' do
    it 'keeps the retry waiting for the next sweep and still enqueues the other messages' do
      failing = new_message(next_retry_at: 1.minute.ago)
      healthy = new_message(next_retry_at: 1.minute.ago)

      allow(Messages::DeliverJob).to receive(:perform_later).and_wrap_original do |original, message_id|
        raise StandardError, 'redis unavailable' if message_id == failing.id

        original.call(message_id)
      end
      allow(Rails.logger).to receive(:error).and_call_original

      described_class.call

      expect(Rails.logger).to have_received(:error).with(/enqueue failed for message #{failing.id}/)
      expect(enqueued_message_ids).to contain_exactly(healthy.id)
      expect(failing.reload.status).to eq('pending')
      expect(failing.next_retry_at).to be_present
    end
  end
end
