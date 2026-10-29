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

        described_class.call

        expect(message.reload.next_retry_at).to be_between(now + 30.minutes, now + (30.minutes * 1.2))
      end
    end

    context 'when the lease expired on the final attempt' do
      before { start_delivery(message, attempt_count: Webhooks::DeliveryPolicy::MAX_ATTEMPTS, lease_expires_at: 1.minute.ago) }

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
