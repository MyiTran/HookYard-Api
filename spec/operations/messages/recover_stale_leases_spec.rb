require 'rails_helper'

describe Messages::RecoverStaleLeases, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:now) { Time.zone.local(2026, 1, 1, 12, 0, 0) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }

  before { travel_to(now) }

  def start_delivery(message, attempt_count:, lease_expires_at:, attempt: true)
    message.update_columns(
      status: 'delivering',
      attempt_count: attempt_count,
      delivery_lease_expires_at: lease_expires_at
    )
    return unless attempt

    create(:delivery_attempt,
           message: message,
           attempt_number: attempt_count,
           request_url: endpoint.url,
           request_body: '{"id":"evt"}')
  end

  describe '.call' do
    context 'when the lease expired during an attempt' do
      before { start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago) }

      it 'returns the message to pending with a retry time' do
        described_class.call

        expect(message.reload.status).to eq('pending')
        expect(message.next_retry_at).to be_between(now + 5.seconds, now + (5.seconds * 1.2))
        expect(message.delivery_lease_expires_at).to be_nil
        expect(message.terminal_at).to be_nil
      end

      it 'records a recoverable abandonment error on the in-progress attempt' do
        attempt = message.delivery_attempts.first

        described_class.call

        attempt.reload
        expect(attempt.error_type).to eq(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
        expect(attempt.error_message).to eq(DeliveryAttempt::LEASE_EXPIRED_MESSAGE)
        expect(attempt.request_url).to eq(endpoint.url)
        expect(attempt.request_body).to eq('{"id":"evt"}')
      end

      it 'does not create another delivery attempt' do
        expect { described_class.call }.not_to change(DeliveryAttempt, :count)
      end

      it 'uses the retry schedule matching the attempts already made' do
        message.update_columns(attempt_count: 3)
        third_delay = Webhooks::DeliveryPolicy::RETRY_DELAYS[2]

        described_class.call

        expect(message.reload.next_retry_at).to be_between(now + third_delay, now + (third_delay * 1.2))
      end

      it 'never counts the lease expiry toward the circuit failures' do
        described_class.call

        expect(endpoint.reload.circuit_failure_count).to eq(0)
        expect(endpoint).to be_enabled
      end
    end

    context 'when the circuit is open for the endpoint' do
      before do
        endpoint.update!(
          circuit_state: 'circuit_open',
          circuit_failure_count: 5,
          circuit_opened_at: now,
          circuit_next_probe_at: now + 1.minute,
          circuit_probe_lease_expires_at: now + 1.minute
        )
        start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago)
      end

      it 'holds the recovered message without touching the probe lease or counters' do
        described_class.call

        message.reload
        endpoint.reload
        expect(message.status).to eq('pending')
        expect(message.hold_reason).to eq('endpoint_circuit_open')
        expect(message.next_retry_at).to be_nil
        expect(message.delivery_attempts.first.error_type).to eq(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
        expect(endpoint.circuit_failure_count).to eq(5)
        expect(endpoint.circuit_probe_lease_expires_at).to eq(now + 1.minute)
        expect(endpoint).to be_circuit_open
      end
    end

    context 'when the lease expired on the final attempt' do
      before do
        start_delivery(
          message,
          attempt_count: Webhooks::DeliveryPolicy::MAX_ATTEMPTS,
          lease_expires_at: 1.minute.ago
        )
      end

      it 'terminally fails the message and releases the lease' do
        described_class.call

        expect(message.reload.status).to eq('failed')
        expect(message.terminal_at).to eq(now)
        expect(message.next_retry_at).to be_nil
        expect(message.delivery_lease_expires_at).to be_nil
        expect(message.delivery_attempts.first.error_type).to eq(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
      end
    end

    context 'when the lease is still active' do
      before { start_delivery(message, attempt_count: 1, lease_expires_at: 5.minutes.from_now) }

      it 'leaves the in-progress delivery untouched' do
        described_class.call

        expect(message.reload.status).to eq('delivering')
        expect(message.delivery_lease_expires_at).to be_present
        expect(message.delivery_attempts.first.error_type).to be_nil
      end
    end

    context 'when the message is terminal' do
      before do
        message.update_columns(
          status: 'succeeded',
          attempt_count: 1,
          delivery_lease_expires_at: 1.minute.ago,
          terminal_at: now
        )
      end

      it 'never overwrites the terminal state' do
        described_class.call

        expect(message.reload.status).to eq('succeeded')
        expect(message.terminal_at).to eq(now)
      end
    end

    context 'when the current attempt recorded a successful response' do
      before do
        start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago)
        message.delivery_attempts.sole.update!(response_status: 200, duration_ms: 40)
      end

      it 'finishes the message as succeeded instead of scheduling another delivery' do
        described_class.call

        message.reload
        expect(message.status).to eq('succeeded')
        expect(message.terminal_at).to eq(now)
        expect(message.next_retry_at).to be_nil
        expect(message.delivery_lease_expires_at).to be_nil
      end

      it 'keeps the recorded attempt evidence untouched' do
        described_class.call

        attempt = message.delivery_attempts.sole.reload
        expect(attempt.response_status).to eq(200)
        expect(attempt.duration_ms).to eq(40)
        expect(attempt.error_type).to be_nil
      end

      it 'resets the endpoint circuit failures' do
        endpoint.update!(circuit_failure_count: 3)

        described_class.call

        expect(endpoint.reload.circuit_failure_count).to eq(0)
      end

      it 'meters the recorded attempt exactly once' do
        described_class.call
        described_class.call

        metrics = DeliveryMetric.where(project: project)
        expect(message.delivery_attempts.sole.reload.metrics_recorded_at).to be_present
        expect(metrics.sum(:attempts_count)).to eq(1)
        expect(metrics.sum(:successes_count)).to eq(1)
      end
    end

    [400, 401].each do |status|
      context "when the current attempt recorded an HTTP #{status}" do
        before do
          start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago)
          message.delivery_attempts.sole.update!(response_status: status)
        end

        it 'terminally fails the message instead of retrying it' do
          described_class.call

          message.reload
          expect(message.status).to eq('failed')
          expect(message.terminal_at).to eq(now)
          expect(message.next_retry_at).to be_nil
          expect(message.delivery_lease_expires_at).to be_nil
        end

        it 'never counts the client error toward the circuit failures' do
          described_class.call

          expect(endpoint.reload.circuit_failure_count).to eq(0)
          expect(endpoint).to be_enabled
        end
      end
    end

    [408, 429, 500].each do |status|
      context "when the current attempt recorded an HTTP #{status}" do
        before do
          start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago)
          message.delivery_attempts.sole.update!(response_status: status)
        end

        it 'reschedules the policy retry without overwriting the recorded evidence' do
          described_class.call

          message.reload
          attempt = message.delivery_attempts.sole
          expect(message.status).to eq('pending')
          expect(message.next_retry_at).to be_between(now + 5.seconds, now + 6.seconds)
          expect(message.delivery_lease_expires_at).to be_nil
          expect(attempt.response_status).to eq(status)
          expect(attempt.error_type).to be_nil
        end

        it 'counts the recorded failure toward the circuit breaker once' do
          described_class.call
          described_class.call

          expect(endpoint.reload.circuit_failure_count).to eq(1)
        end
      end
    end

    context 'when the current attempt recorded a retryable transport error' do
      before do
        start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago)
        message.delivery_attempts.sole.update!(error_type: 'Net::ReadTimeout', error_message: 'Net::ReadTimeout')
      end

      it 'reschedules the policy retry and counts the failure' do
        described_class.call

        expect(message.reload.next_retry_at).to be_between(now + 5.seconds, now + 6.seconds)
        expect(message.delivery_attempts.sole.reload.error_type).to eq('Net::ReadTimeout')
        expect(endpoint.reload.circuit_failure_count).to eq(1)
      end
    end

    context 'when the current attempt recorded a non-retryable transport error' do
      before do
        start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago)
        message.delivery_attempts.sole.update!(error_type: 'ArgumentError', error_message: 'bad uri')
      end

      it 'terminally fails the message' do
        described_class.call

        message.reload
        expect(message.status).to eq('failed')
        expect(message.terminal_at).to eq(now)
        expect(message.delivery_attempts.sole.reload.error_type).to eq('ArgumentError')
      end
    end

    context 'when a replay attempt recorded a result but the current attempt did not' do
      let(:run) { create(:replay_run, project: project) }

      before do
        start_delivery(message, attempt_count: 2, lease_expires_at: 1.minute.ago)
        replay_item = create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                                          status: ReplayItem::DELIVERING_STATUS,
                                          delivery_lease_expires_at: 1.minute.ago)
        create(:delivery_attempt, message: message, attempt_number: 3, replay_item: replay_item,
                                  response_status: 200)
      end

      it 'recovers the interrupted delivery instead of trusting the replay result' do
        described_class.call

        message.reload
        expect(message.status).to eq('pending')
        expect(message.next_retry_at).to be_present
        expect(message.delivery_attempts.find_by(attempt_number: 2).error_type)
                       .to eq(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
        expect(message.delivery_attempts.find_by(attempt_number: 3).response_status).to eq(200)
      end
    end

    context 'when the stale owner finalizes after recovery' do
      before do
        start_delivery(message, attempt_count: 1, lease_expires_at: 1.minute.ago)
        message.delivery_attempts.sole.update!(response_status: 503)
      end

      it 'never double counts the circuit failure or the attempt metric' do
        described_class.call
        Messages::Deliver.new(http_client: double('http_client')).call(message: message)

        metrics = DeliveryMetric.where(project: project)
        expect(endpoint.reload.circuit_failure_count).to eq(1)
        expect(metrics.sum(:attempts_count)).to eq(1)
        expect(message.reload.status).to eq('pending')
      end
    end

    context 'when a delivering message has no lease' do
      before { message.update_columns(status: 'delivering', attempt_count: 1, delivery_lease_expires_at: nil) }

      it 'recovers it as stale' do
        described_class.call

        expect(message.reload.status).to eq('pending')
        expect(message.next_retry_at).to be_present
      end
    end

    context 'when the lease expired before any attempt was recorded' do
      before { start_delivery(message, attempt_count: 0, lease_expires_at: 1.minute.ago, attempt: false) }

      it 'keeps the message waiting for the first attempt' do
        described_class.call

        expect(message.reload.status).to eq('pending')
        expect(message.next_retry_at).to be_present
        expect(message.delivery_lease_expires_at).to be_nil
      end
    end
  end
end
