require 'rails_helper'

describe Messages::Deliver, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }
  let(:signer) { Webhooks::Signer }
  let(:http_client) { double('http_client') }
  let(:operation) { described_class.new(http_client: http_client, signer: signer) }

  before { travel_to(Time.zone.local(2026, 1, 1, 12, 0, 0)) }

  def http_result(status: nil, error: nil, error_type: nil)
    Webhooks::HttpClient::Result.new(
      status: status,
      headers: {},
      body: status.nil? ? nil : 'response body',
      duration_ms: 12,
      error: error,
      error_type: error_type
    )
  end

  def deliver(result)
    allow(http_client).to receive(:post).and_return(result)
    operation.call(message: message)
  end

  def create_active_delivery(target_endpoint, lease_expires_at: 30.seconds.from_now)
    active_message = create(:message, project: target_endpoint.project, endpoint: target_endpoint)
    active_message.update_columns(
      status: 'delivering',
      attempt_count: 1,
      delivery_lease_expires_at: lease_expires_at
    )
    active_message
  end

  describe 'terminal success' do
    it 'marks the message succeeded and records the attempt evidence' do
      deliver(http_result(status: 204))

      expect(message.reload.status).to eq('succeeded')
      expect(message.attempt_count).to eq(1)
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.terminal_at).to eq(Time.current)
      expect(message.delivery_attempts.one?).to be(true)
      expect(message.delivery_attempts.first.response_status).to eq(204)
    end
  end

  describe 'retryable failures' do
    {
      'a network error' => { error: 'connection refused', error_type: 'Errno::ECONNREFUSED' },
      'a read timeout' => { error: 'read timeout', error_type: 'Net::ReadTimeout' },
      'an open timeout' => { error: 'open timeout', error_type: 'Net::OpenTimeout' },
      'an HTTP 408' => { status: 408 },
      'an HTTP 429' => { status: 429 },
      'an HTTP 500' => { status: 500 },
      'an HTTP 503' => { status: 503 }
    }.each do |label, result_attributes|
      it "reschedules after #{label}" do
        deliver(http_result(**result_attributes))

        expect(message.reload.status).to eq('pending')
        expect(message.attempt_count).to eq(1)
        expect(message.terminal_at).to be_nil
        expect(message.delivery_lease_expires_at).to be_nil
        expect(message.next_retry_at).to be_between(Time.current + 1.minute, Time.current + (1.minute * 1.2))
        expect(message.delivery_attempts.one?).to be(true)
        expect(message.delivery_attempts.first.status).to eq('failed')
      end
    end

    it 'persists the timeout error type on the delivery attempt' do
      deliver(http_result(error: 'execution expired', error_type: 'Net::ReadTimeout'))

      attempt = message.delivery_attempts.first
      expect(attempt.error_type).to eq('Net::ReadTimeout')
      expect(attempt.error_message).to eq('execution expired')
      expect(attempt.response_status).to be_nil
    end

    it 'uses the configured schedule for later attempts' do
      message.update_columns(attempt_count: 2)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500)
      create(:delivery_attempt, message: message, attempt_number: 2, response_status: 500)

      deliver(http_result(status: 500))

      expect(message.reload.next_retry_at).to be_between(Time.current + 15.minutes, Time.current + (15.minutes * 1.2))
    end

    it 'enqueues the next delivery for the retry time' do
      allow(http_client).to receive(:post).and_return(http_result(status: 503))

      operation.call(message: message)

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to eq(Messages::DeliverJob)
      expect(job[:args]).to eq([message.id])
      expect(job[:at]).to be_within(0.001).of(message.next_retry_at.to_f)
    end
  end

  describe 'non-retryable failures' do
    [301, 400, 404, 422].each do |status|
      it "terminally fails the message on HTTP #{status}" do
        deliver(http_result(status: status))

        expect(message.reload.status).to eq('failed')
        expect(message.next_retry_at).to be_nil
        expect(message.delivery_lease_expires_at).to be_nil
        expect(message.terminal_at).to eq(Time.current)
        expect(message.delivery_attempts.first.response_status).to eq(status)
      end
    end

    it 'terminally fails on a security error without retrying' do
      deliver(http_result(error: 'destination is not publicly routable',
                          error_type: 'Webhooks::DestinationResolver::NotPubliclyRoutable'))

      expect(message.reload.status).to eq('failed')
      expect(message.next_retry_at).to be_nil
      expect(message.terminal_at).to eq(Time.current)
    end

    it 'terminally fails when the endpoint has no signing secret' do
      endpoint.endpoint_signing_secrets.destroy_all

      deliver(http_result(status: 200))

      expect(message.reload.status).to eq('failed')
      expect(message.delivery_attempts).to be_empty
      expect(message.attempt_count).to eq(0)
      expect(message.delivery_lease_expires_at).to be_nil
    end

    it 'terminally fails when signing raises instead of retrying' do
      failing_signer = double('signer')
      allow(failing_signer).to receive(:sign).and_raise(StandardError, 'bad key')
      failing_operation = described_class.new(http_client: http_client, signer: failing_signer)

      failing_operation.call(message: message)

      expect(message.reload.status).to eq('failed')
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_attempts).to be_empty
      expect(message.attempt_count).to eq(0)
    end
  end

  describe 'attempt exhaustion' do
    it 'terminally fails after the fifth attempt' do
      4.times do |index|
        create(:delivery_attempt, message: message, attempt_number: index + 1, response_status: 500)
      end
      message.update_columns(attempt_count: 4)

      deliver(http_result(status: 503))

      expect(message.reload.status).to eq('failed')
      expect(message.attempt_count).to eq(5)
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.terminal_at).to eq(Time.current)
      expect(message.delivery_attempts.count).to eq(5)
    end

    it 'does not deliver a message that already used every attempt' do
      message.update_columns(attempt_count: 5)

      allow(http_client).to receive(:post)
      operation.call(message: message)

      expect(http_client).not_to have_received(:post)
      expect(message.reload.status).to eq('failed')
    end
  end

  describe 'retry lifecycle' do
    it 'creates another delivery attempt for the same message without creating a new message' do
      allow(http_client).to receive(:post).and_return(http_result(status: 500), http_result(status: 200))

      operation.call(message: message)
      travel(2.minutes)
      operation.call(message: message)

      expect(message.reload.status).to eq('succeeded')
      expect(message.attempt_count).to eq(2)
      expect(message.delivery_attempts.count).to eq(2)
      expect(message.delivery_attempts.map(&:attempt_number)).to eq([1, 2])
      expect(Message.where(event_id: event.id, endpoint_id: endpoint.id).count).to eq(1)
      expect(message.delivery_lease_expires_at).to be_nil
    end

    it 'skips a message whose next retry is not due yet' do
      message.update_columns(next_retry_at: 1.minute.from_now)
      allow(http_client).to receive(:post)

      operation.call(message: message)

      expect(http_client).not_to have_received(:post)
      expect(message.reload.delivery_attempts).to be_empty
      expect(message.attempt_count).to eq(0)
    end
  end

  describe 'duplicate execution' do
    it 'does not create a second concurrent attempt for the same message' do
      allow(http_client).to receive(:post) do
        described_class.new(http_client: double(post: http_result(status: 200)), signer: signer).call(message: message)
        http_result(status: 204)
      end

      operation.call(message: message)

      expect(message.reload.delivery_attempts.count).to eq(1)
      expect(message.status).to eq('succeeded')
    end
  end

  describe 'endpoint concurrency' do
    it 'allows at most three active deliveries per endpoint' do
      3.times { create_active_delivery(endpoint) }
      allow(http_client).to receive(:post)

      operation.call(message: message)

      expect(http_client).not_to have_received(:post)
      expect(message.reload.status).to eq('pending')
      expect(message.attempt_count).to eq(0)
      expect(message.delivery_attempts).to be_empty
      expect(message.next_retry_at).to be_between(Time.current + 15.seconds, Time.current + (15.seconds * 1.2))
      expect(message.terminal_at).to be_nil
    end

    it 'ignores expired leases when counting active deliveries' do
      3.times { create_active_delivery(endpoint, lease_expires_at: 1.second.ago) }
      allow(http_client).to receive(:post).and_return(http_result(status: 200))

      operation.call(message: message)

      expect(message.reload.status).to eq('succeeded')
    end

    it 'delivers concurrently on a different endpoint' do
      other_endpoint = create(:endpoint, project: project)
      3.times { create_active_delivery(other_endpoint) }
      allow(http_client).to receive(:post).and_return(http_result(status: 200))

      operation.call(message: message)

      expect(message.reload.status).to eq('succeeded')
    end
  end

  describe 'lease ownership' do
    it 'does not overwrite a message recovered after the lease expired' do
      recovered_attempt = nil
      allow(http_client).to receive(:post) do
        Messages::RecoverStaleLeases.call(now: 10.minutes.from_now)
        recovered_attempt = message.reload.delivery_attempts.first
        http_result(status: 200)
      end

      operation.call(message: message)

      expect(message.reload.status).to eq('pending')
      expect(message.terminal_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(recovered_attempt.error_type).to eq(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
    end
  end
end
