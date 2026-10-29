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

  def enqueued_probe_endpoint_ids
    ActiveJob::Base.queue_adapter.enqueued_jobs
                       .select { |job| job[:job] == CircuitProbes::RunJob }
                       .map { |job| job[:args].first }
  end

  describe '#perform' do
    it 'disables the automatic Sidekiq retry so the cron sweep owns the timing' do
      expect(described_class.sidekiq_options['retry']).to be(false)
    end

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

    it 'does not disable an open circuit just because the disable window elapsed' do
      Webhooks::CircuitPolicy.disable_window = 5.seconds
      endpoint.update!(
        circuit_state: 'circuit_open',
        circuit_failure_count: 5,
        circuit_opened_at: 1.hour.ago,
        circuit_disable_at: 1.hour.ago + 5.seconds,
        circuit_next_probe_at: 1.minute.from_now
      )

      described_class.new.perform

      endpoint.reload
      expect(endpoint).to be_circuit_open
      expect(endpoint.circuit_next_probe_at).to be_present
      expect(enqueued_probe_endpoint_ids).to be_empty
    end

    it 'enqueues one synthetic probe for an endpoint whose probe is due' do
      endpoint.update!(
        circuit_state: 'circuit_open',
        circuit_failure_count: 5,
        circuit_opened_at: 1.minute.ago,
        circuit_disable_at: 1.minute.ago + 5.days,
        circuit_next_probe_at: 1.second.ago
      )

      described_class.new.perform

      expect(enqueued_probe_endpoint_ids).to eq([endpoint.id])
    end

    it 'does not enqueue a synthetic probe while a probe lease is active' do
      endpoint.update!(
        circuit_state: 'circuit_open',
        circuit_failure_count: 5,
        circuit_opened_at: 1.minute.ago,
        circuit_disable_at: 1.minute.ago + 5.days,
        circuit_next_probe_at: 1.second.ago,
        circuit_probe_lease_expires_at: 1.minute.from_now
      )

      described_class.new.perform

      expect(enqueued_probe_endpoint_ids).to be_empty
    end
  end
end
