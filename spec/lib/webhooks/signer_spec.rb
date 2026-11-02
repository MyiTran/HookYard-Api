require 'rails_helper'

describe Webhooks::Signer do
  let(:secret) { "whsec_#{Base64.strict_encode64(SecureRandom.random_bytes(32))}" }
  let(:webhook_id) { "msg_#{SecureRandom.uuid}" }
  let(:timestamp) { Time.current }
  let(:body) { '{"type":"order.created","data":{"order_id":"ord_1"}}' }

  describe '.sign' do
    it 'produces a versioned signature that verifies against the same secret' do
      signature = described_class.sign(secret: secret, webhook_id: webhook_id, timestamp: timestamp, body: body)

      expect(signature).to start_with('v1,')
      expect(
        described_class.verify(secret: secret, webhook_id: webhook_id, timestamp: timestamp, body: body, signature: signature)
      ).to eq('type' => 'order.created', 'data' => { 'order_id' => 'ord_1' })
    end

    it 'supports legacy url-safe base64 secrets' do
      legacy_secret = SecureRandom.urlsafe_base64(Endpoint::SIGNING_SECRET_BYTES)
      signature = described_class.sign(secret: legacy_secret, webhook_id: webhook_id, timestamp: timestamp, body: body)

      expect(
        described_class.verify(secret: legacy_secret, webhook_id: webhook_id, timestamp: timestamp, body: body, signature: signature)
      ).to include('type' => 'order.created')
    end

    it 'produces the same signature as the standard webhooks library' do
      signature = described_class.sign(secret: secret, webhook_id: webhook_id, timestamp: timestamp, body: body)
      expected = StandardWebhooks::Webhook.new(secret).sign(webhook_id, timestamp.to_i, body)

      expect(signature).to eq(expected)
    end
  end

  describe '.verify' do
    let(:signature) { described_class.sign(secret: secret, webhook_id: webhook_id, timestamp: timestamp, body: body) }

    it 'rejects a tampered body' do
      expect do
        described_class.verify(
          secret: secret,
          webhook_id: webhook_id,
          timestamp: timestamp,
          body: "#{body} ",
          signature: signature
        )
      end.to raise_error(StandardWebhooks::WebhookVerificationError)
    end

    it 'rejects a signature created with another secret' do
      other_secret = "whsec_#{Base64.strict_encode64(SecureRandom.random_bytes(32))}"

      expect do
        described_class.verify(
          secret: other_secret,
          webhook_id: webhook_id,
          timestamp: timestamp,
          body: body,
          signature: signature
        )
      end.to raise_error(StandardWebhooks::WebhookVerificationError)
    end

    it 'rejects an expired timestamp' do
      expect do
        described_class.verify(
          secret: secret,
          webhook_id: webhook_id,
          timestamp: 10.minutes.ago,
          body: body,
          signature: signature
        )
      end.to raise_error(StandardWebhooks::WebhookVerificationError)
    end
  end
end
