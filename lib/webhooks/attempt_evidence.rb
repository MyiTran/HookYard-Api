module Webhooks
  module AttemptEvidence
    USER_AGENT = 'HookYard/1.0'
    REQUEST_ID_PREFIX = 'req_'

    module_function

    def attributes(message:, secret:, attempt_number:, signer: Webhooks::Signer, at: Time.current)
      request_id = "#{REQUEST_ID_PREFIX}#{SecureRandom.uuid}"
      webhook_id = message.webhook_id
      body = body_for(message)

      {
        attempt_number: attempt_number,
        request_id: request_id,
        webhook_id: webhook_id,
        signing_secret_version: secret.version,
        signed_at: at,
        request_url: request_url_for(message),
        http_method: 'POST',
        request_headers: headers_for(
          signer: signer, secret: secret.secret, webhook_id: webhook_id, request_id: request_id, signed_at: at, body: body
        ),
        request_body: body
      }
    end

    def headers_for(signer:, secret:, webhook_id:, request_id:, signed_at:, body:)
      {
        'content-type' => 'application/json',
        'user-agent' => USER_AGENT,
        'webhook-id' => webhook_id,
        'webhook-timestamp' => signed_at.to_i.to_s,
        'webhook-signature' => signer.sign(secret: secret, webhook_id: webhook_id, timestamp: signed_at, body: body),
        'webhook-request-id' => request_id
      }
    end

    def body_for(message)
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

    def request_url_for(message)
      uri = URI.parse(message.endpoint.url)
      uri.user = nil
      uri.password = nil
      uri.to_s
    rescue URI::Error
      message.endpoint.url
    end
  end
end
