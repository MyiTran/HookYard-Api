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

    it 'enqueues pending messages that never had a retry time' do
      fresh = new_message

      described_class.call

      expect(enqueued_message_ids).to contain_exactly(fresh.id)
    end

    it 'does not enqueue messages whose retry is still in the future' do
      new_message(next_retry_at: 1.minute.from_now)

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end

    it 'does not enqueue delivering or terminal messages' do
      new_message(status: :delivering)
      new_message(status: :succeeded)
      new_message(status: :failed)

      described_class.call

      expect(enqueued_message_ids).to be_empty
    end
  end
end
