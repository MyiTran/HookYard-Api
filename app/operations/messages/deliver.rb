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

      claim = claim_attempt!

      return reschedule_after_capacity(claim) if claim.outcome == :capacity_full
      return message.reload unless claim.outcome == :claimed

      result = http_client.post(
        url: claim.attempt.request_url,
        headers: claim.attempt.request_headers,
        body: claim.attempt.request_body,
        timeout: Webhooks::DeliveryPolicy.timeout_seconds_for(message.endpoint.project)
      )
      finalize!(claim, result)

      message.reload
    end

    private

    attr_reader :http_client, :signer, :message

    def claim_attempt!
      message.endpoint.with_lock do
        message.reload
        claim_locked!
      end
    end

    def claim_locked!
      endpoint = message.endpoint.reload
      return Claim.new(outcome: :skipped) unless claimable?

      return skip_while_not_enabled!(endpoint) unless endpoint.enabled?
      return Claim.new(outcome: :skipped) if message.held?
      return exhaust_attempts! unless message.retries_available?
      return reschedule_for_capacity! if endpoint_at_capacity?

      claim_with_secret!(endpoint)
    end

    def skip_while_not_enabled!(endpoint)
      message.hold!(reason: endpoint.circuit_hold_reason) unless message.held?
      Claim.new(outcome: :skipped)
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

    def exhaust_attempts!
      message.mark_failed!
      Claim.new(outcome: :exhausted)
    end

    def reschedule_for_capacity!
      retry_at = Time.current + Webhooks::DeliveryPolicy.capacity_retry_delay
      message.schedule_retry!(at: retry_at)

      Claim.new(outcome: :capacity_full, retry_at: retry_at)
    end

    def claim_with_secret!(endpoint)
      secret = current_secret
      return failed_claim! if secret.nil?

      attempt_number = next_attempt_number
      attributes = build_attempt_attributes!(secret, attempt_number)
      return failed_claim! if attributes.nil?

      lease_expires_at = Time.current + Webhooks::DeliveryPolicy.delivery_lease_duration
      message.mark_delivering!(lease_expires_at: lease_expires_at, attempt_count: attempt_number)
      attempt = message.delivery_attempts.create!(attributes)

      Claim.new(outcome: :claimed, attempt: attempt, lease_expires_at: lease_expires_at)
    end

    def failed_claim!
      message.mark_failed!
      Claim.new(outcome: :failed)
    end

    def build_attempt_attributes!(secret, attempt_number)
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

    def finalize!(claim, result)
      retry_at = nil
      endpoint = message.endpoint
      outcome = nil

      DeliveryAttempt.transaction do
        endpoint.with_lock do
          message.with_lock do
            outcome = finalize_attempt_evidence!(claim, result)
            next unless outcome == :recorded

            if owns_lease?(claim.lease_expires_at)
              DeliveryMetric.record_attempt!(claim.attempt.reload)
              retry_at = transition_after_result!(result)
              resolve_circuit!(endpoint.reload, result)
              hold_for_open_circuit!(endpoint.reload) if retry_at
            else
              outcome = :lease_lost
            end
          end
        end
      end

      enqueue_retry(retry_at) if retry_at && !message.reload.held?
      log_finalization(claim, outcome)
    rescue StandardError
      log_finalization(claim, :finalization_failed)
      preserve_evidence_after_finalization_failure!(claim, result)
      raise
    end

    def hold_for_open_circuit!(endpoint)
      return if endpoint.enabled?

      message.reload
      message.hold!(reason: endpoint.circuit_hold_reason) unless message.held?
    end

    def owns_lease?(lease_expires_at)
      message.delivering? && message.delivery_lease_expires_at == lease_expires_at
    end

    def finalize_attempt_evidence!(claim, result)
      attempt = claim.attempt.reload
      return :already_completed if attempt.completed?

      return :recorded if record_evidence_if_pending!(attempt, result)

      claim.attempt.reload.completed? ? :recovery_won : :lease_lost
    end

    def record_evidence_if_pending!(attempt, result)
      DeliveryAttempt.where(id: attempt.id, response_status: nil, error_type: nil)
                     .update_all(evidence_attributes(result).merge(updated_at: Time.current)) == 1
    end

    def evidence_attributes(result)
      if result.error?
        {
          error_type: result.error_type,
          error_message: DeliveryAttempt.truncate_error_message(result.error),
          duration_ms: result.duration_ms
        }
      elsif result.status.present?
        {
          response_status: result.status,
          response_headers: DeliveryAttempt.filter_headers(result.headers),
          response_body: DeliveryAttempt.truncate_response_body(result.body),
          duration_ms: result.duration_ms
        }
      else
        {
          error_type: DeliveryAttempt::LEASE_SUPERSEDED_ERROR_TYPE,
          error_message: DeliveryAttempt::LEASE_SUPERSEDED_MESSAGE,
          duration_ms: result.duration_ms
        }
      end
    end

    def preserve_evidence_after_finalization_failure!(claim, result)
      DeliveryAttempt.transaction(requires_new: true) do
        attempt = claim.attempt.reload
        record_evidence_if_pending!(attempt, result || interruption_result) unless attempt.completed?
      end
    rescue StandardError
      nil
    end

    def interruption_result
      Webhooks::HttpClient::Result.new(
        error: DeliveryAttempt::FINALIZATION_INTERRUPTED_MESSAGE,
        error_type: DeliveryAttempt::FINALIZATION_INTERRUPTED_ERROR_TYPE
      )
    end

    def log_finalization(claim, outcome)
      attempt = claim.attempt.reload
      Rails.logger.info(
        {
          event: 'delivery_finalization',
          message_id: message.id,
          attempt_id: attempt.id,
          expected_lease_expires_at: claim.lease_expires_at&.iso8601(6),
          current_message_status: message.status,
          current_lease_expires_at: message.delivery_lease_expires_at&.iso8601(6),
          attempt_completed: attempt.completed?,
          finalization_outcome: outcome
        }.to_json
      )
    rescue StandardError
      nil
    end

    def transition_after_result!(result)
      if Webhooks::CircuitPolicy.success?(result)
        message.mark_succeeded!
        return nil
      end

      retry_at = retry_at_for(result)
      if retry_at
        message.schedule_retry!(at: retry_at)
        retry_at
      else
        message.mark_failed!
        nil
      end
    end

    def retry_at_for(result)
      return nil unless retryable_result?(result) && message.retries_available?

      delay = Webhooks::DeliveryPolicy.retry_delay(message.attempt_count, project: project)
      delay && Time.current + delay
    end

    def resolve_circuit!(endpoint, result)
      if Webhooks::CircuitPolicy.success?(result)
        reset_circuit_failures!(endpoint)
      else
        endpoint.register_circuit_failure!(result)
      end
    end

    def reset_circuit_failures!(endpoint)
      return unless endpoint.enabled?
      return if endpoint.circuit_failure_count.zero?

      endpoint.update!(circuit_failure_count: 0)
    end

    def retryable_result?(result)
      Webhooks::DeliveryPolicy.retryable?(result)
    end

    def project
      message.endpoint.project
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
