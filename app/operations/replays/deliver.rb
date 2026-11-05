module Replays
  class Deliver < ApplicationOperation
    EVIDENCE_ERROR_TYPE = 'ReplayEvidenceError'

    Claim = Struct.new(:outcome, :attempt, :lease_expires_at, keyword_init: true) do
      def claimed?
        outcome == :claimed
      end
    end

    def initialize(http_client: Webhooks::HttpClient.new, signer: Webhooks::Signer)
      @http_client = http_client
      @signer = signer
    end

    def call(item:)
      @item = item
      claim = claim_attempt
      return item.reload unless claim.claimed?

      result = http_client.post(
        url: claim.attempt.request_url,
        headers: claim.attempt.request_headers,
        body: claim.attempt.request_body,
        timeout: Webhooks::DeliveryPolicy.timeout_seconds_for(item.message.endpoint.project)
      )
      finalize(claim, result)

      item.reload
    end

    private

    attr_reader :http_client, :signer, :item

    def claim_attempt
      endpoint.with_lock do
        endpoint.reload
        item.reload
        claim_locked
      end
    end

    def claim_locked
      return skipped unless item.queued?
      return skip_item(ReplayItem::SKIP_REASON_ENDPOINT_ARCHIVED) if endpoint.archived?
      return skip_item(ReplayItem::SKIP_REASON_ENDPOINT_PAUSED) if endpoint.paused?
      return skip_item(ReplayItem::SKIP_REASON_ENDPOINT_DISABLED) if endpoint.disabled?
      return hold_item if endpoint.circuit_open?
      return reschedule_for_capacity if endpoint_at_capacity?

      claim_with_secret
    end

    def claim_with_secret
      secret = EndpointSigningSecret.current.find_by(endpoint_id: endpoint.id)
      return fail_item(ReplayItem::MISSING_SECRET_ERROR_TYPE, ReplayItem::MISSING_SECRET_MESSAGE) if secret.nil?

      claim_with_attempt(secret)
    end

    def claim_with_attempt(secret)
      lease_expires_at = Time.current + Webhooks::DeliveryPolicy.delivery_lease_duration
      attributes = Webhooks::AttemptEvidence.attributes(
        message: item.message, secret: secret, attempt_number: next_attempt_number, signer: signer
      )

      item.mark_delivering!(lease_expires_at: lease_expires_at)
      attempt = item.message.delivery_attempts.create!(attributes.merge(replay_item_id: item.id))

      Claim.new(outcome: :claimed, attempt: attempt, lease_expires_at: lease_expires_at)
    rescue StandardError => e
      fail_item(EVIDENCE_ERROR_TYPE, e.message)
    end

    def next_attempt_number
      (item.message.delivery_attempts.maximum(:attempt_number) || 0) + 1
    end

    def endpoint_at_capacity?
      active = endpoint.messages.with_active_lease.count +
               ReplayItem.with_active_lease.where(endpoint_id: endpoint.id).count

      active >= Webhooks::DeliveryPolicy::MAX_ACTIVE_DELIVERIES_PER_ENDPOINT
    end

    def reschedule_for_capacity
      Replays::DeliverJob.set(wait: Webhooks::DeliveryPolicy.capacity_retry_delay).perform_later(item.id)
      skipped
    end

    def hold_item
      item.mark_held!(reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
      skipped
    end

    def skip_item(reason)
      item.mark_skipped!(reason: reason)
      skipped
    end

    def fail_item(error_type, error_message)
      item.mark_failed!(
        error_type: error_type,
        error_message: Webhooks::ResponseEvidence.truncate_error_message(error_message)
      )

      Claim.new(outcome: :failed)
    end

    def skipped
      Claim.new(outcome: :skipped)
    end

    def finalize(claim, result)
      DeliveryAttempt.transaction do
        endpoint.with_lock do
          endpoint.reload
          item.with_lock do
            item.reload
            next unless owns_lease?(claim)

            record_result(claim.attempt, result)
            finish_item(result)
            Webhooks::CircuitTracker.apply(endpoint: endpoint.reload, result: result)
          end
        end
      end
    end

    def owns_lease?(claim)
      item.delivering? && item.delivery_lease_expires_at == claim.lease_expires_at
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
    end

    def finish_item(result)
      if Webhooks::CircuitPolicy.success?(result)
        item.mark_succeeded!
        item.message.mark_succeeded_by_replay!
      else
        item.mark_failed!(error_type: failure_type(result), error_message: failure_message(result))
      end
    end

    def failure_type(result)
      result.error? ? result.error_type : nil
    end

    def failure_message(result)
      return nil unless result.error?

      DeliveryAttempt.truncate_error_message(result.error)
    end

    def endpoint
      item.endpoint
    end
  end
end
