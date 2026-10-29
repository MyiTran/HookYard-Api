module Messages
  class Deliver < ApplicationOperation
    USER_AGENT = 'HookYard/1.0'

    Claim = Struct.new(:outcome, :attempt, :lease_expires_at, :retry_at, keyword_init: true)

    def initialize(http_client: Webhooks::HttpClient.new, signer: Webhooks::Signer)
      @http_client = http_client
      @signer = signer
    end

    def call(message:)
      @message = message
      message.reload
      return message if message.terminal?

      claim = claim_attempt

      return reschedule_after_capacity(claim) if claim.outcome == :capacity_full
      return message.reload unless claim.outcome == :claimed

      result = http_client.post(
        url: claim.attempt.request_url,
        headers: claim.attempt.request_headers,
        body: claim.attempt.request_body
      )
      finalize(claim, result)

      message.reload
    end

    private

    attr_reader :http_client, :signer, :message

    def claim_attempt
      message.endpoint.with_lock do
        message.reload
        return Claim.new(outcome: :skipped) unless claimable?
        return exhaust_attempts unless message.retries_available?
        return reschedule_for_capacity if endpoint_at_capacity?

        secret = current_secret
        return fail_without_secret if secret.nil?

        claim_with_attempt(secret)
      end
    end

    def claimable?
      message.pending? && due?
    end

    def due?
      message.next_retry_at.nil? || message.next_retry_at <= Time.current
    end

    def endpoint_at_capacity?
      message.endpoint.messages
             .with_active_lease
             .where.not(id: message.id)
             .count >= Webhooks::DeliveryPolicy::MAX_ACTIVE_DELIVERIES_PER_ENDPOINT
    end

    def exhaust_attempts
      message.mark_failed!
      Claim.new(outcome: :exhausted)
    end

    def reschedule_for_capacity
      retry_at = Time.current + Webhooks::DeliveryPolicy.capacity_retry_delay
      message.schedule_retry!(at: retry_at)

      Claim.new(outcome: :capacity_full, retry_at: retry_at)
    end

    def fail_without_secret
      message.mark_failed!
      Claim.new(outcome: :failed)
    end

    def claim_with_attempt(secret)
      attempt_number = next_attempt_number
      attributes = build_attempt_attributes(secret, attempt_number)
      return Claim.new(outcome: :failed) if attributes.nil?

      message.mark_delivering!(
        lease_expires_at: Time.current + Webhooks::DeliveryPolicy.delivery_lease_duration,
        attempt_count: attempt_number
      )
      lease_expires_at = message.reload.delivery_lease_expires_at
      attempt = message.delivery_attempts.create!(attributes)

      Claim.new(outcome: :claimed, attempt: attempt, lease_expires_at: lease_expires_at)
    end

    def build_attempt_attributes(secret, attempt_number)
      attempt_attributes(secret, attempt_number)
    rescue StandardError
      message.mark_failed!
      nil
    end

    def current_secret
      EndpointSigningSecret.current.find_by(endpoint_id: message.endpoint_id)
    end

    def attempt_attributes(secret, attempt_number)
      signed_at = Time.current
      request_id = "req_#{SecureRandom.uuid}"
      body = webhook_body
      webhook_id = message.webhook_id

      {
        attempt_number: attempt_number,
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

    def finalize(claim, result)
      retry_at = nil

      DeliveryAttempt.transaction do
        message.with_lock do
          message.reload
          next if superseded?(claim)

          retry_at = record_result(claim.attempt, result)
        end
      end

      enqueue_retry(retry_at) if retry_at
    end

    def superseded?(claim)
      claim.attempt.reload.completed? || !owns_lease?(claim.lease_expires_at)
    end

    def owns_lease?(lease_expires_at)
      message.delivering? && message.delivery_lease_expires_at == lease_expires_at
    end

    def record_result(attempt, result)
      if result.error?
        attempt.update!(
          error_type: result.error_type,
          error_message: DeliveryAttempt.truncate_error_message(result.error),
          duration_ms: result.duration_ms
        )
      else
        attempt.update!(
          response_status: result.status,
          response_headers: DeliveryAttempt.filter_headers(result.headers),
          response_body: DeliveryAttempt.truncate_response_body(result.body),
          duration_ms: result.duration_ms
        )
      end

      transition_after_result(result)
    end

    def transition_after_result(result)
      if succeeded_result?(result)
        message.mark_succeeded!
        nil
      elsif retryable_result?(result) && message.retries_available?
        schedule_retry
      else
        message.mark_failed!
        nil
      end
    end

    def schedule_retry
      retry_at = Time.current + Webhooks::DeliveryPolicy.retry_delay(message.attempt_count)
      message.schedule_retry!(at: retry_at)

      retry_at
    end

    def succeeded_result?(result)
      !result.error? && result.status.to_i.between?(200, 299)
    end

    def retryable_result?(result)
      Webhooks::DeliveryPolicy.retryable?(result)
    end

    def reschedule_after_capacity(claim)
      enqueue_retry(claim.retry_at)
      message.reload
    end

    def enqueue_retry(at)
      Messages::DeliverJob.set(wait_until: at).perform_later(message.id)
    end
  end
end
