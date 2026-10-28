require 'rails_helper'

describe Messages::Deliver, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project, event_types: ['order.created']) }
  let(:event) { create(:event, project: project, event_type: 'order.created', payload: { 'order_id' => 'ord_1' }) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }
  let(:signer) { Webhooks::Signer }
  let(:http_client) { double('http_client') }
  let(:operation) { described_class.new(http_client: http_client, signer: signer) }
  let(:sent_requests) { [] }

  before { travel_to(Time.zone.local(2026, 1, 1, 12, 0, 0)) }

  def http_result(status: nil, error: nil, error_type: nil, headers: {}, body: nil, duration_ms: 12)
    Webhooks::HttpClient::Result.new(
      status: status,
      headers: headers,
      body: body || (status.nil? ? nil : 'response body'),
      duration_ms: duration_ms,
      error: error,
      error_type: error_type
    )
  end

  def deliver(result)
    allow(http_client).to receive(:post).and_return(result)
    operation.call(message: message)
  end

  def verify_signature(attempt, secret)
    Webhooks::Signer.verify(
      secret: secret,
      webhook_id: attempt.webhook_id,
      timestamp: attempt.signed_at.to_i,
      body: attempt.request_body,
      signature: attempt.request_headers['webhook-signature']
    )
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

  describe 'request evidence' do
    before do
      allow(http_client).to receive(:post) do |url:, headers:, body:|
        sent_requests << { url: url, headers: headers, body: body }
        http_result(status: 200)
      end
    end

    it 'records request evidence that matches what was sent' do
      operation.call(message: message)

      attempt = message.delivery_attempts.first
      sent = sent_requests.first

      expect(attempt.request_url).to eq(sent[:url])
      expect(attempt.http_method).to eq('POST')
      expect(attempt.request_headers).to eq(sent[:headers])
      expect(attempt.request_body).to eq(sent[:body])
      expect(attempt.attempt_number).to eq(1)
    end

    it 'signs the exact body that is sent' do
      operation.call(message: message)

      attempt = message.delivery_attempts.first
      payload = verify_signature(attempt, endpoint.current_signing_secret.secret)

      expect(payload).to include('type' => 'order.created', 'id' => event.id)
      expect(attempt.request_headers['webhook-id']).to eq(attempt.webhook_id)
      expect(attempt.request_headers['webhook-request-id']).to eq(attempt.request_id)
    end

    it 'records the signing secret version that was used' do
      operation.call(message: message)

      expect(message.delivery_attempts.first.signing_secret_version).to eq(1)
    end
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

    it 'stores the response evidence and drops credential headers' do
      deliver(
        http_result(
          status: 200,
          headers: { 'content-type' => ['application/json'], 'set-cookie' => ['session=secret'] },
          body: '{"ok":true}',
          duration_ms: 15
        )
      )

      attempt = message.delivery_attempts.first
      expect(attempt.response_status).to eq(200)
      expect(attempt.response_headers).to eq('content-type' => ['application/json'])
      expect(attempt.response_body).to eq('{"ok":true}')
      expect(attempt.duration_ms).to eq(15)
      expect(message.reload).to be_succeeded
    end

    it 'stores a capped response body' do
      deliver(http_result(status: 200, body: 'a' * 5000))

      expect(message.delivery_attempts.first.response_body.bytesize)
        .to eq(DeliveryAttempt::RESPONSE_BODY_MAX_BYTES)
    end
  end

  describe 'signing secret rotation' do
    it 'uses the new current version for new deliveries' do
      legacy_secret = endpoint.current_signing_secret.secret
      deliver(http_result(status: 200))
      endpoint.rotate_signing_secret!

      second_message = create(:message, event: create(:event, project: project), endpoint: endpoint)
      described_class.new(http_client: http_client, signer: signer).call(message: second_message)

      attempt = second_message.delivery_attempts.first
      expect(attempt.signing_secret_version).to eq(2)
      expect(verify_signature(attempt, endpoint.current_signing_secret.secret)).to include('type' => 'order.created')
      expect { verify_signature(attempt, legacy_secret) }
        .to raise_error(StandardWebhooks::WebhookVerificationError)
    end

    it 'keeps the original version on historical attempts' do
      deliver(http_result(status: 200))
      endpoint.rotate_signing_secret!

      expect(message.delivery_attempts.first.reload.signing_secret_version).to eq(1)
    end

    it 'never starts a delivery with a secret retired before the claim' do
      retired_secret = endpoint.current_signing_secret.secret
      endpoint.rotate_signing_secret!

      deliver(http_result(status: 200))

      attempt = message.delivery_attempts.first
      expect(attempt.signing_secret_version).to eq(2)
      expect(verify_signature(attempt, endpoint.current_signing_secret.secret)).to include('type' => 'order.created')
      expect { verify_signature(attempt, retired_secret) }
        .to raise_error(StandardWebhooks::WebhookVerificationError)
    end
  end

  describe 'external text encoding' do
    let(:binary_payload) { "binary\xFF\xFE".b }

    it 'stores a binary receiver body as valid UTF-8' do
      deliver(http_result(status: 204, body: binary_payload))

      expect(message.reload.status).to eq('succeeded')
      expect(message.delivery_attempts.first.response_body).to be_valid_encoding
    end

    it 'keeps the response evidence and schedules the retry for a retryable binary response' do
      deliver(http_result(status: 502, headers: { 'x-trace' => [binary_payload] }, body: binary_payload))

      attempt = message.delivery_attempts.first
      expect(attempt.response_body).to be_valid_encoding
      expect(attempt.response_headers['x-trace'].first).to be_valid_encoding
      expect(message.reload.status).to eq('pending')
      expect(message.next_retry_at).to be_present
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
        expect(message.next_retry_at).to be_between(Time.current + 5.seconds, Time.current + (5.seconds * 1.2))
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
      expect(attempt).to be_transport_failed
    end

    it 'uses the configured schedule for later attempts' do
      message.update_columns(attempt_count: 2)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500)
      create(:delivery_attempt, message: message, attempt_number: 2, response_status: 500)

      deliver(http_result(status: 500))

      expect(message.reload.attempt_count).to eq(3)
      expect(message.next_retry_at).to be_between(Time.current + 30.minutes, Time.current + (30.minutes * 1.2))
    end

    it 'follows the whole eight attempt lifecycle before giving up' do
      allow(http_client).to receive(:post).and_return(http_result(status: 503))

      (Webhooks::DeliveryPolicy::MAX_ATTEMPTS - 1).times do |index|
        operation.call(message: message)

        message.reload
        expect(message.attempt_count).to eq(index + 1)
        expect(message.status).to eq('pending')

        expected_delay = Webhooks::DeliveryPolicy::RETRY_DELAYS[index]
        expect(message.next_retry_at).to be_between(Time.current + expected_delay, Time.current + (expected_delay * 1.2))
        travel(expected_delay * 1.2 + 1.minute)
      end

      operation.call(message: message)

      message.reload
      expect(message.attempt_count).to eq(8)
      expect(message.status).to eq('failed')
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_attempts.count).to eq(8)
    end

    it 'enqueues the next delivery for the retry time' do
      allow(http_client).to receive(:post).and_return(http_result(status: 503))

      operation.call(message: message)

      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to eq(Messages::DeliverJob)
      expect(job[:args]).to eq([message.id])
      expect(job[:at]).to be_within(0.001).of(message.next_retry_at.to_f)
    end

    it 'does not send again once the message succeeded' do
      deliver(http_result(status: 200))
      operation.call(message: Message.find(message.id))

      expect(http_client).to have_received(:post).once
      expect(message.delivery_attempts.count).to eq(1)
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
    it 'terminally fails after the last attempt' do
      (Webhooks::DeliveryPolicy::MAX_ATTEMPTS - 1).times do |index|
        create(:delivery_attempt, message: message, attempt_number: index + 1, response_status: 500)
      end
      message.update_columns(attempt_count: Webhooks::DeliveryPolicy::MAX_ATTEMPTS - 1)

      deliver(http_result(status: 503))

      expect(Webhooks::DeliveryPolicy::MAX_ATTEMPTS).to eq(8)
      expect(message.reload.status).to eq('failed')
      expect(message.attempt_count).to eq(Webhooks::DeliveryPolicy::MAX_ATTEMPTS)
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.terminal_at).to eq(Time.current)
      expect(message.delivery_attempts.count).to eq(Webhooks::DeliveryPolicy::MAX_ATTEMPTS)
    end

    it 'does not deliver a message that already used every attempt' do
      message.update_columns(attempt_count: Webhooks::DeliveryPolicy::MAX_ATTEMPTS)

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
