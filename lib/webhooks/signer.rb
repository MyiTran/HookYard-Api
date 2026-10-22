require 'base64'
require 'openssl'

module Webhooks
  # Creates and verifies Standard Webhooks signatures for outbound deliveries.
  # Uses the whsec_ key material and canonical webhook headers.
  # Accepts legacy URL-safe encoded secrets only for backward compatibility.
  class Signer
    SECRET_PREFIX = 'whsec_'

    def self.sign(secret:, webhook_id:, timestamp:, body:)
      webhook(secret).sign(webhook_id, timestamp.to_i, body)
    end

    def self.verify(secret:, webhook_id:, timestamp:, body:, signature:)
      webhook(secret).verify(
        body,
        {
          'webhook-id' => webhook_id,
          'webhook-timestamp' => timestamp.to_i.to_s,
          'webhook-signature' => signature
        }
      )
    end

    def self.key_for(secret)
      encoded = secret.delete_prefix(SECRET_PREFIX)

      decode_standard_key(encoded) || decode_legacy_key(encoded) || encoded
    end

    def self.webhook(secret)
      StandardWebhooks::Webhook.new(Base64.strict_encode64(key_for(secret)))
    end
    private_class_method :webhook

    def self.decode_standard_key(encoded)
      Base64.strict_decode64(encoded)
    rescue ArgumentError
      nil
    end
    private_class_method :decode_standard_key

    def self.decode_legacy_key(encoded)
      Base64.urlsafe_decode64(encoded)
    rescue ArgumentError
      nil
    end
    private_class_method :decode_legacy_key
  end
end
