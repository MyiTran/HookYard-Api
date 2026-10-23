require 'rails_helper'

describe Messages::RetrySweepJob, type: :job do
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

  describe '#perform' do
    it 'recovers stale leases and enqueues due retries' do
      stale = new_message
      stale.update_columns(status: 'delivering', attempt_count: 1, delivery_lease_expires_at: 1.minute.ago)
      create(:delivery_attempt, message: stale, attempt_number: 1)

      due = new_message(next_retry_at: 1.minute.ago)
      future = new_message(next_retry_at: 1.minute.from_now)

      described_class.new.perform

      expect(stale.reload.status).to eq('pending')
      expect(stale.delivery_lease_expires_at).to be_nil
      expect(stale.delivery_attempts.first.error_type).to eq(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
      expect(enqueued_message_ids).to include(due.id)
      expect(enqueued_message_ids).not_to include(future.id)
    end

    it 'is safe to run twice' do
      stale = new_message
      stale.update_columns(status: 'delivering', attempt_count: 1, delivery_lease_expires_at: 1.minute.ago)

      described_class.new.perform
      described_class.new.perform

      expect(stale.reload.delivery_attempts).to be_empty
      expect(stale.status).to eq('pending')
      expect(stale.next_retry_at).to be_present
    end
  end
end
