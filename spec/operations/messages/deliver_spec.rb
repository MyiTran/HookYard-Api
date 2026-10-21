require 'rails_helper'

describe Messages::Deliver, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project, event_types: ['order.created']) }
  let(:event) { create(:event, project: project, event_type: 'order.created', payload: { 'order_id' => 'ord_1' }) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }
  let(:http_client) { instance_double(Webhooks::HttpClient) }
  let(:sent_requests) { [] }
  let(:http_result) do
    Webhooks::HttpClient::Result.new(
      status: 200,
      headers: { 'content-type' => ['application/json'], 'set-cookie' => ['session=secret'] },
      body: '{"ok":true}',
      duration_ms: 15
    )
  end

  before do
    allow(http_client).to receive(:post) do |url:, headers:, body:|
      sent_requests << { url: url, headers: headers, body: body }
      http_result
    end
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

  describe '.call' do
    it 'records request evidence that matches what was sent' do
      described_class.new(http_client: http_client).call(message: message)

      attempt = message.delivery_attempts.first
      sent = sent_requests.first

      expect(attempt.request_url).to eq(sent[:url])
      expect(attempt.http_method).to eq('POST')
      expect(attempt.request_headers).to eq(sent[:headers])
      expect(attempt.request_body).to eq(sent[:body])
      expect(attempt.attempt_number).to eq(1)
    end

    it 'signs the exact body that is sent' do
      described_class.new(http_client: http_client).call(message: message)

      attempt = message.delivery_attempts.first
      payload = verify_signature(attempt, endpoint.current_signing_secret.secret)

      expect(payload).to include('type' => 'order.created', 'id' => event.id)
      expect(attempt.request_headers['webhook-id']).to eq(attempt.webhook_id)
      expect(attempt.request_headers['webhook-request-id']).to eq(attempt.request_id)
    end

    it 'records the signing secret version that was used' do
      described_class.new(http_client: http_client).call(message: message)

      expect(message.delivery_attempts.first.signing_secret_version).to eq(1)
    end

    context 'when the endpoint responds with a 2xx status' do
      it 'stores the response and marks the message succeeded' do
        described_class.new(http_client: http_client).call(message: message)

        attempt = message.delivery_attempts.first
        expect(attempt.response_status).to eq(200)
        expect(attempt.response_headers).to eq('content-type' => ['application/json'])
        expect(attempt.response_body).to eq('{"ok":true}')
        expect(attempt.duration_ms).to eq(15)
        expect(message.reload).to be_succeeded
      end
    end

    context 'when the endpoint responds with an error status' do
      let(:http_result) do
        Webhooks::HttpClient::Result.new(
          status: 503,
          headers: { 'content-type' => ['text/plain'] },
          body: 'unavailable',
          duration_ms: 20
        )
      end

      it 'stores the response evidence and marks the message failed' do
        described_class.new(http_client: http_client).call(message: message)

        attempt = message.delivery_attempts.first
        expect(attempt.response_status).to eq(503)
        expect(attempt.response_body).to eq('unavailable')
        expect(attempt.error_type).to be_nil
        expect(message.reload).to be_failed
      end
    end

    context 'when the transport fails' do
      let(:http_result) do
        Webhooks::HttpClient::Result.new(
          error: 'execution expired',
          error_type: 'Net::OpenTimeout',
          duration_ms: 10_000
        )
      end

      it 'stores the transport error separately from the response' do
        described_class.new(http_client: http_client).call(message: message)

        attempt = message.delivery_attempts.first
        expect(attempt.response_status).to be_nil
        expect(attempt.error_type).to eq('Net::OpenTimeout')
        expect(attempt.error_message).to eq('execution expired')
        expect(attempt).to be_transport_failed
        expect(message.reload).to be_failed
      end
    end

    context 'when the response body is longer than the cap' do
      let(:http_result) do
        Webhooks::HttpClient::Result.new(status: 200, headers: {}, body: 'a' * 5000, duration_ms: 5)
      end

      it 'stores a capped body' do
        described_class.new(http_client: http_client).call(message: message)

        expect(message.delivery_attempts.first.response_body.bytesize).to eq(DeliveryAttempt::RESPONSE_BODY_MAX_BYTES)
      end
    end

    context 'when the message already succeeded' do
      it 'does not send again' do
        described_class.new(http_client: http_client).call(message: message)
        described_class.new(http_client: http_client).call(message: message)

        expect(http_client).to have_received(:post).once
        expect(message.delivery_attempts.count).to eq(1)
      end
    end

    context 'when another worker has already claimed the message' do
      it 'neither creates a second attempt nor sends a second request' do
        second_client = instance_double(Webhooks::HttpClient)
        allow(second_client).to receive(:post)
        duplicate_result = nil

        allow(http_client).to receive(:post) do |url:, headers:, body:|
          sent_requests << { url: url, headers: headers, body: body }
          duplicate_result = described_class.new(http_client: second_client).call(message: Message.find(message.id))
          http_result
        end

        described_class.new(http_client: http_client).call(message: message)

        expect(second_client).not_to have_received(:post)
        expect(duplicate_result).to be_delivering
        expect(sent_requests.size).to eq(1)
        expect(message.delivery_attempts.count).to eq(1)
      end
    end

    context 'when the endpoint signing secret has been rotated' do
      it 'uses the new current version for new deliveries' do
        legacy_secret = endpoint.current_signing_secret.secret
        described_class.new(http_client: http_client).call(message: message)
        endpoint.rotate_signing_secret!

        second_message = create(:message, event: create(:event, project: project), endpoint: endpoint)
        described_class.new(http_client: http_client).call(message: second_message)

        attempt = second_message.delivery_attempts.first
        expect(attempt.signing_secret_version).to eq(2)
        expect(verify_signature(attempt, endpoint.current_signing_secret.secret)).to include('type' => 'order.created')
        expect { verify_signature(attempt, legacy_secret) }
          .to raise_error(StandardWebhooks::WebhookVerificationError)
      end

      it 'keeps the original version on historical attempts' do
        described_class.new(http_client: http_client).call(message: message)
        endpoint.rotate_signing_secret!

        expect(message.delivery_attempts.first.reload.signing_secret_version).to eq(1)
      end

      it 'never starts a delivery with a secret retired before the claim' do
        retired_secret = endpoint.current_signing_secret.secret
        endpoint.rotate_signing_secret!

        described_class.new(http_client: http_client).call(message: message)

        attempt = message.delivery_attempts.first
        expect(attempt.signing_secret_version).to eq(2)
        expect(verify_signature(attempt, endpoint.current_signing_secret.secret)).to include('type' => 'order.created')
        expect { verify_signature(attempt, retired_secret) }
          .to raise_error(StandardWebhooks::WebhookVerificationError)
      end
    end
  end
end
