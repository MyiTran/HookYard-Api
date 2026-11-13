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

  describe 'delivery usage metering' do
    it 'does not charge the monthly delivery quota for delivery retries' do
      deliver(http_result(status: 503))

      expect(message.reload.status).to eq('pending')
      expect(message.next_retry_at).to be_present
      expect(project.billing_owner.deliveries_used_in_period).to eq(0)
    end
  end

  describe '.call' do
    it 'delivers through the public operation api with the default dependencies' do
      allow(Webhooks::HttpClient).to receive(:new).and_return(http_client)
      allow(http_client).to receive(:post).and_return(http_result(status: 200))

      described_class.call(message: message)

      expect(message.reload.status).to eq('succeeded')
      expect(http_client).to have_received(:post).once
      expect(message.delivery_attempts.sole.response_status).to eq(200)
    end
  end

  describe 'request evidence' do
    before do
      allow(http_client).to receive(:post) do |url:, headers:, body:, timeout:|
        sent_requests << { url: url, headers: headers, body: body, timeout: timeout }
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
      expect(sent[:timeout]).to eq(Webhooks::DeliveryPolicy::HTTP_TIMEOUT_SECONDS)
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

  describe 'retry schedule before the circuit opens' do
    before { Webhooks::DeliveryPolicy.jitter_source = -> { 0 } }

    it 'follows the fixed free schedule for the first four failures' do
      allow(http_client).to receive(:post).and_return(http_result(status: 503))

      [5.seconds, 5.minutes, 30.minutes, 2.hours].each_with_index do |delay, index|
        message.update_columns(next_retry_at: Time.current)

        operation.call(message: message.reload)

        expect(message.reload.next_retry_at).to be_within(1.second).of(Time.current + delay)
        expect(message.attempt_count).to eq(index + 1)
        expect(endpoint.reload).to be_enabled
      end
    end

    it 'opens the circuit on the fifth failure without rewriting the earlier retries' do
      allow(http_client).to receive(:post).and_return(http_result(status: 503))

      5.times do
        message.update_columns(next_retry_at: Time.current)
        operation.call(message: message.reload)
      end

      expect(endpoint.reload).to be_circuit_open
      expect(message.reload).to be_held
      expect(message.next_retry_at).to be_nil
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

    it 'follows the whole eight attempt lifecycle on HTTP 500 before giving up' do
      stub_const('Webhooks::CircuitPolicy::FAILURE_THRESHOLD', 100)
      allow(http_client).to receive(:post).and_return(http_result(status: 500))

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
      described_class.new(http_client: http_client, signer: signer).call(message: Message.find(message.id))

      expect(http_client).to have_received(:post).once
      expect(message.delivery_attempts.count).to eq(1)
    end
  end

  describe 'destination resolution' do
    let(:resolver) { double('resolver') }
    let(:operation) { described_class.new(http_client: Webhooks::HttpClient.new(resolver: resolver), signer: signer) }

    context 'when the dns lookup times out' do
      before { allow(resolver).to receive(:resolve).and_raise(Webhooks::DestinationResolver::ResolutionFailed) }

      it 'retries the message on the schedule' do
        operation.call(message: message)

        message.reload
        expect(message.status).to eq('pending')
        expect(message.attempt_count).to eq(1)
        expect(message.next_retry_at).to be_between(Time.current + 5.seconds, Time.current + (5.seconds * 1.2))
      end

      it 'records the resolution failure on the attempt' do
        operation.call(message: message)

        attempt = message.reload.delivery_attempts.first
        expect(attempt.error_type).to eq('Webhooks::DestinationResolver::ResolutionFailed')
        expect(attempt.response_status).to be_nil
      end
    end

    context 'when the dns resolver reports an error' do
      it 'retries the message on the schedule' do
        allow(resolver).to receive(:resolve)
          .and_raise(Webhooks::DestinationResolver::ResolutionFailed.new('destination resolution failed'))

        operation.call(message: message)

        message.reload
        expect(message.status).to eq('pending')
        expect(message.next_retry_at).to be_between(Time.current + 5.seconds, Time.current + (5.seconds * 1.2))
      end
    end

    context 'when the dns lookup returns no address' do
      it 'retries the message on the schedule' do
        allow(resolver).to receive(:resolve).and_raise(Webhooks::DestinationResolver::ResolutionFailed)

        operation.call(message: message)

        expect(message.reload.status).to eq('pending')
      end
    end

    context 'when the destination is not publicly routable' do
      before { allow(resolver).to receive(:resolve).and_raise(Webhooks::DestinationResolver::NotPubliclyRoutable) }

      it 'terminally fails the message without a retry' do
        operation.call(message: message)

        message.reload
        expect(message.status).to eq('failed')
        expect(message.attempt_count).to eq(1)
        expect(message.next_retry_at).to be_nil
        expect(message.terminal_at).to eq(Time.current)
        expect(message.delivery_attempts.first.error_type)
          .to eq('Webhooks::DestinationResolver::NotPubliclyRoutable')
      end

      it 'still resolves the destination before every retried attempt' do
        allow(resolver).to receive(:resolve).and_raise(Webhooks::DestinationResolver::NotPubliclyRoutable)

        operation.call(message: message)

        message.update_columns(next_retry_at: 1.minute.ago)
        operation.call(message: message)

        expect(resolver).to have_received(:resolve).once
        expect(message.reload.attempt_count).to eq(1)
      end
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
      stub_const('Webhooks::DeliveryPolicy::MAX_ATTEMPTS', 3)
      2.times do |index|
        create(:delivery_attempt, message: message, attempt_number: index + 1, response_status: 500)
      end
      message.update_columns(attempt_count: 2)

      deliver(http_result(status: 503))

      expect(message.reload.status).to eq('failed')
      expect(message.attempt_count).to eq(3)
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.terminal_at).to eq(Time.current)
      expect(message.delivery_attempts.count).to eq(3)
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

  describe 'tenant delivery policy' do
    it 'uses the free plan timeout of fifteen seconds by default' do
      allow(http_client).to receive(:post).and_return(http_result(status: 200))

      operation.call(message: message)

      expect(http_client).to have_received(:post).with(hash_including(timeout: 15))
    end

    it 'uses the configured pro plan timeout' do
      project.billing_owner.update!(plan: User::PRO_PLAN)
      project.update!(delivery_timeout_seconds: 30)
      allow(http_client).to receive(:post).and_return(http_result(status: 200))

      operation.call(message: message)

      expect(http_client).to have_received(:post).with(hash_including(timeout: 30))
    end

    it 'uses the configured pro plan retry delays' do
      project.billing_owner.update!(plan: User::PRO_PLAN)
      project.update!(delivery_retry_delays_seconds: [3])
      allow(http_client).to receive(:post).and_return(http_result(status: 503))

      operation.call(message: message)

      expect(message.reload.next_retry_at).to be_between(Time.current + 3.seconds, Time.current + 4.seconds)
    end
  end

  describe 'circuit failure accounting' do
    def deliver_message(target, result)
      allow(http_client).to receive(:post).and_return(result)
      described_class.new(http_client: http_client, signer: signer).call(message: target)
    end

    def new_message
      create(:message, project: project, endpoint: endpoint)
    end

    it 'resets the consecutive circuit failures after a 2xx response' do
      endpoint.update_columns(circuit_failure_count: 3)

      deliver(http_result(status: 200))

      expect(endpoint.reload.circuit_failure_count).to eq(0)
    end

    {
      'an HTTP 408' => { status: 408 },
      'an HTTP 429' => { status: 429 },
      'an HTTP 500' => { status: 500 },
      'a read timeout' => { error: 'read timeout', error_type: 'Net::ReadTimeout' },
      'a transport error' => { error: 'connection reset', error_type: 'Errno::ECONNRESET' }
    }.each do |label, result_attributes|
      it "counts #{label} toward the circuit failure count" do
        deliver(http_result(**result_attributes))

        expect(endpoint.reload.circuit_failure_count).to eq(1)
      end
    end

    it 'does not count a redirect toward the circuit failures' do
      deliver(http_result(status: 302))

      expect(message.reload.status).to eq('failed')
      expect(endpoint.reload.circuit_failure_count).to eq(0)
    end

    it 'does not count a non-retryable client error toward the circuit failures' do
      deliver(http_result(status: 404))

      expect(message.reload.status).to eq('failed')
      expect(endpoint.reload.circuit_failure_count).to eq(0)
    end

    it 'does not count a rejected destination toward the circuit failures' do
      deliver(
        http_result(
          error: 'destination is not publicly routable',
          error_type: 'Webhooks::DestinationResolver::NotPubliclyRoutable'
        )
      )

      expect(message.reload.status).to eq('failed')
      expect(message.terminal_at).to eq(Time.current)
      expect(message.next_retry_at).to be_nil
      expect(endpoint.reload.circuit_failure_count).to eq(0)
      expect(endpoint).to be_enabled
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == Messages::DeliverJob }).to be_empty
    end

    it 'counts four HTTP 500 responses without opening the circuit' do
      4.times { deliver_message(new_message, http_result(status: 500)) }

      endpoint.reload
      expect(endpoint).to be_enabled
      expect(endpoint.circuit_failure_count).to eq(4)
      expect(endpoint.circuit_opened_at).to be_nil
      expect(endpoint.messages.pending.not_held.count).to eq(4)
    end

    it 'counts a transient destination resolution failure toward the circuit failures' do
      deliver(
        http_result(
          error: 'destination hostname could not be resolved',
          error_type: 'Webhooks::DestinationResolver::ResolutionFailed'
        )
      )

      endpoint.reload
      expect(endpoint.circuit_failure_count).to eq(1)
      expect(endpoint).to be_enabled
      expect(message.reload.status).to eq('pending')
      expect(message.next_retry_at).to be_between(Time.current + 5.seconds, Time.current + 6.seconds)
    end

    it 'does not count a signing failure toward the circuit failures' do
      failing_signer = double('signer')
      allow(failing_signer).to receive(:sign).and_raise(StandardError, 'bad key')

      described_class.new(http_client: http_client, signer: failing_signer).call(message: message)

      expect(message.reload.status).to eq('failed')
      expect(endpoint.reload.circuit_failure_count).to eq(0)
    end

    it 'does not count a missing signing secret toward the circuit failures' do
      endpoint.endpoint_signing_secrets.destroy_all

      deliver(http_result(status: 200))

      expect(message.reload.status).to eq('failed')
      expect(endpoint.reload.circuit_failure_count).to eq(0)
    end

    it 'keeps the endpoint enabled while failures stay below the threshold' do
      4.times { deliver_message(new_message, http_result(status: 503)) }

      expect(endpoint.reload).to be_enabled
      expect(endpoint.circuit_failure_count).to eq(4)
    end

    it 'keeps a timeout failure retryable and circuit-counted' do
      deliver(http_result(error: 'execution expired', error_type: 'Net::ReadTimeout'))

      endpoint.reload
      expect(endpoint.circuit_failure_count).to eq(1)
      expect(message.reload.status).to eq('pending')
      expect(message.attempt_count).to eq(1)
      expect(message.next_retry_at).to be_present
      expect(message.delivery_attempts.last.failure_category).to eq(Webhooks::FailureCategory::TIMEOUT)
    end

    it 'opens the circuit on the fifth consecutive failure and holds pending messages' do
      4.times { deliver_message(new_message, http_result(status: 503)) }
      last_failure = new_message

      deliver_message(last_failure, http_result(status: 503))

      endpoint.reload
      expect(endpoint).to be_circuit_open
      expect(endpoint.circuit_failure_count).to eq(5)
      expect(endpoint.circuit_opened_at).to eq(Time.current)
      expect(endpoint.circuit_next_probe_at).to be_present
      expect(endpoint.messages.pending.held.count).to eq(5)
      expect(last_failure.reload.hold_reason).to eq('endpoint_circuit_open')
      expect(last_failure.delivery_attempts.count).to eq(1)
    end

    it 'resets the failure streak when a success happens before the threshold' do
      2.times { deliver_message(new_message, http_result(status: 503)) }
      deliver_message(new_message, http_result(status: 200))
      2.times { deliver_message(new_message, http_result(status: 503)) }

      expect(endpoint.reload).to be_enabled
      expect(endpoint.circuit_failure_count).to eq(2)
    end
  end

  describe 'messages in flight when the circuit opens' do
    def new_message
      create(:message, project: project, endpoint: endpoint)
    end

    it 'holds every message whose attempt finishes after the circuit opened' do
      Webhooks::DeliveryPolicy.jitter_source = -> { 0 }
      endpoint.update!(circuit_failure_count: Webhooks::CircuitPolicy::FAILURE_THRESHOLD - 2)
      trigger = new_message
      other_in_flight = create(:message, project: project, endpoint: endpoint)

      nested = described_class.new(http_client: double(post: http_result(status: 503)), signer: signer)
      allow(http_client).to receive(:post) do
        nested.call(message: other_in_flight)
        http_result(status: 503)
      end

      operation.call(message: trigger)

      expect(endpoint.reload).to be_circuit_open
      [trigger, other_in_flight].each do |record|
        record.reload
        expect(record.status).to eq('pending')
        expect(record.held_at).to be_present
        expect(record.hold_reason).to eq('endpoint_circuit_open')
        expect(record.next_retry_at).to be_nil
        expect(record.attempt_count).to eq(1)
      end
    end

    it 'does not schedule a retry for a message that joined the held backlog' do
      allow(http_client).to receive(:post) do
        endpoint.open_circuit!
        http_result(status: 503)
      end

      operation.call(message: message)

      expect(message.reload).to be_held
      expect(message.next_retry_at).to be_nil
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == Messages::DeliverJob }).to be_empty
    end

    it 'keeps the attempt count untouched by the circuit transition' do
      allow(http_client).to receive(:post) do
        endpoint.open_circuit!
        http_result(status: 503)
      end

      expect { operation.call(message: message) }.to change { message.reload.attempt_count }.from(0).to(1)
    end
  end

  describe 'delivery while the endpoint is not enabled' do
    def held_message(created_at: Time.current, reason: 'endpoint_circuit_open')
      create(:message, project: project, endpoint: endpoint).tap do |record|
        record.update_columns(
          held_at: created_at,
          hold_reason: reason,
          created_at: created_at,
          updated_at: created_at
        )
      end
    end

    context 'when the circuit is open' do
      before do
        endpoint.update!(
          circuit_state: 'circuit_open',
          circuit_failure_count: 5,
          circuit_opened_at: Time.current,
          circuit_disable_at: Time.current + 5.days,
          circuit_next_probe_at: Time.current
        )
      end

      it 'holds the message without consuming an attempt or sending a request' do
        record = create(:message, project: project, endpoint: endpoint)
        allow(http_client).to receive(:post)

        operation.call(message: record)

        expect(http_client).not_to have_received(:post)
        expect(record.reload.status).to eq('pending')
        expect(record.attempt_count).to eq(0)
        expect(record.delivery_attempts).to be_empty
        expect(record).to be_held
        expect(record.hold_reason).to eq('endpoint_circuit_open')
      end

      it 'keeps an already held message frozen without sending it as a probe' do
        record = held_message
        allow(http_client).to receive(:post)

        operation.call(message: record)

        expect(http_client).not_to have_received(:post)
        expect(record.reload.held_at).to eq(Time.current)
        expect(record.attempt_count).to eq(0)
        expect(record.delivery_attempts).to be_empty
      end

      it 'never touches the synthetic probe lease' do
        record = create(:message, project: project, endpoint: endpoint)
        endpoint.update!(circuit_probe_lease_expires_at: Time.current + 30.seconds)

        operation.call(message: record)

        expect(endpoint.reload.circuit_probe_lease_expires_at).to eq(Time.current + 30.seconds)
      end
    end

    context 'when the endpoint is disabled' do
      before { endpoint.update!(circuit_state: 'disabled', circuit_next_probe_at: nil) }

      it 'holds the message with the disabled reason and sends nothing' do
        record = create(:message, project: project, endpoint: endpoint)
        allow(http_client).to receive(:post)

        operation.call(message: record)

        expect(http_client).not_to have_received(:post)
        expect(record.reload).to be_held
        expect(record.hold_reason).to eq('endpoint_disabled')
        expect(record.attempt_count).to eq(0)
        expect(endpoint.reload).to be_disabled
      end
    end
  end
end
