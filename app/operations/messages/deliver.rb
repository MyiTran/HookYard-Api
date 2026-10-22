module Messages
  class Deliver < ApplicationOperation
    USER_AGENT = 'HookYard/1.0'

    def initialize(http_client: Webhooks::HttpClient.new, signer: Webhooks::Signer)
      @http_client = http_client
      @signer = signer
    end

    def call(message:)
      @message = message
      return message if message.succeeded?

      attempt = claim_attempt
      return message.reload if attempt.nil?

      result = http_client.post(url: attempt.request_url, headers: attempt.request_headers, body: attempt.request_body)
      complete_attempt(attempt, result)

      message.reload
    end

    private

    attr_reader :http_client, :signer, :message

    def claim_attempt
      message.endpoint.with_lock do
        message.reload
        return nil unless message.pending?

        secret = current_secret
        return fail_without_secret if secret.nil?

        message.update!(status: :delivering)
        message.delivery_attempts.create!(attempt_attributes(secret))
      end
    end

    def current_secret
      EndpointSigningSecret.current.find_by(endpoint_id: message.endpoint_id)
    end

    def fail_without_secret
      message.update!(status: :failed)
      nil
    end

    def attempt_attributes(secret)
      signed_at = Time.current
      request_id = "req_#{SecureRandom.uuid}"
      body = webhook_body
      webhook_id = message.webhook_id

      {
        attempt_number: next_attempt_number,
        request_id: request_id,
        webhook_id: webhook_id,
        signing_secret_version: secret.version,
        signed_at: signed_at,
        request_url: request_url,
        http_method: 'POST',
        request_headers: request_headers(secret: secret, webhook_id: webhook_id, request_id: request_id, signed_at: signed_at, body: body),
        request_body: body
      }
    end

    def request_headers(secret:, webhook_id:, request_id:, signed_at:, body:)
      {
        'content-type' => 'application/json',
        'user-agent' => USER_AGENT,
        'webhook-id' => webhook_id,
        'webhook-timestamp' => signed_at.to_i.to_s,
        'webhook-signature' => signer.sign(secret: secret.secret, webhook_id: webhook_id, timestamp: signed_at, body: body),
        'webhook-request-id' => request_id
      }
    end

    def webhook_body
      event = message.event

      Oj.dump(
        {
          id: event.id,
          type: event.event_type,
          created_at: event.created_at.iso8601,
          data: event.payload
        },
        mode: :compat
      )
    end

    def request_url
      uri = URI.parse(message.endpoint.url)
      uri.user = nil
      uri.password = nil
      uri.to_s
    rescue URI::Error
      message.endpoint.url
    end

    def next_attempt_number
      (message.delivery_attempts.maximum(:attempt_number) || 0) + 1
    end

    def complete_attempt(attempt, result)
      DeliveryAttempt.transaction do
        if result.error?
          record_transport_error(attempt, result)
        else
          record_response(attempt, result)
        end
      end
    end

    def record_transport_error(attempt, result)
      attempt.update!(
        error_type: result.error_type,
        error_message: DeliveryAttempt.truncate_error_message(result.error),
        duration_ms: result.duration_ms
      )
      message.update!(status: :failed)
    end

    def record_response(attempt, result)
      attempt.update!(
        response_status: result.status,
        response_headers: DeliveryAttempt.filter_headers(result.headers),
        response_body: DeliveryAttempt.truncate_response_body(result.body),
        duration_ms: result.duration_ms
      )
      message.update!(status: attempt.succeeded? ? :succeeded : :failed)
    end
  end
end
