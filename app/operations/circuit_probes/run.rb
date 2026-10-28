module CircuitProbes
  class Run < ApplicationOperation
    # Receivers must treat this payload as a health check and never as a business event.
    PAYLOAD_TYPE = 'endpoint.test'
    ID_PREFIX = 'probe_'
    USER_AGENT = 'HookYard/1.0'
    MISSING_SECRET_ERROR_TYPE = 'CircuitProbeSigningSecretMissing'
    MISSING_SECRET_MESSAGE = 'endpoint has no current signing secret'

    Claim = Struct.new(:outcome, :probe, :lease_expires_at, :request_url, :headers, :body, keyword_init: true) do
      def claimed?
        outcome == :claimed
      end
    end

    def initialize(http_client: Webhooks::HttpClient.new, signer: Webhooks::Signer)
      @http_client = http_client
      @signer = signer
    end

    def call(endpoint:)
      @endpoint = endpoint
      claim = claim_probe

      return endpoint.reload unless claim.claimed?

      result = http_client.post(
        url: claim.request_url,
        headers: claim.headers,
        body: claim.body,
        timeout: Webhooks::DeliveryPolicy.timeout_seconds_for(endpoint.project)
      )
      finalize(claim, result)

      endpoint.reload
    end

    private

    attr_reader :http_client, :signer, :endpoint

    def claim_probe
      endpoint.with_lock do
        endpoint.reload
        return Claim.new(outcome: :skipped) unless endpoint.probe_due?(now)
        return Claim.new(outcome: :skipped) if endpoint.probe_in_flight?(now)

        secret = EndpointSigningSecret.current.find_by(endpoint_id: endpoint.id)

        if secret.nil?
          record_missing_secret
          return Claim.new(outcome: :skipped)
        end

        expire_abandoned_probe
        endpoint.acquire_probe_lease!(at: now)

        build_claim(secret)
      end
    end

    def build_claim(secret)
      probe = endpoint.circuit_probes.new(probe_attributes(secret))
      probe.save!

      Claim.new(
        outcome: :claimed,
        probe: probe,
        lease_expires_at: endpoint.reload.circuit_probe_lease_expires_at,
        request_url: probe.request_url,
        headers: request_headers(probe, secret),
        body: probe.request_body
      )
    end

    def probe_attributes(secret)
      webhook_id = generate_id

      {
        request_id: generate_id,
        webhook_id: webhook_id,
        signing_secret_version: secret.version,
        started_at: now,
        request_url: request_url,
        request_body: request_body(webhook_id)
      }
    end

    def generate_id
      "#{ID_PREFIX}#{SecureRandom.uuid}"
    end

    def request_body(webhook_id)
      Oj.dump(
        {
          id: webhook_id,
          type: PAYLOAD_TYPE,
          created_at: now.utc.iso8601,
          data: { endpoint_id: endpoint.id, probe: true }
        },
        mode: :compat
      )
    end

    def request_headers(probe, secret)
      {
        'content-type' => 'application/json',
        'user-agent' => USER_AGENT,
        'webhook-id' => probe.webhook_id,
        'webhook-timestamp' => probe.started_at.to_i.to_s,
        'webhook-signature' => signer.sign(
          secret: secret.secret,
          webhook_id: probe.webhook_id,
          timestamp: probe.started_at,
          body: probe.request_body
        ),
        'webhook-request-id' => probe.request_id
      }
    end

    def request_url
      uri = URI.parse(endpoint.url)
      uri.user = nil
      uri.password = nil
      uri.to_s
    rescue URI::Error
      endpoint.url
    end

    def record_missing_secret
      webhook_id = generate_id

      endpoint.circuit_probes.create!(
        request_id: generate_id,
        webhook_id: webhook_id,
        signing_secret_version: nil,
        started_at: now,
        request_url: endpoint.url,
        request_body: request_body(webhook_id),
        status: :failed,
        completed_at: now,
        error_type: MISSING_SECRET_ERROR_TYPE,
        error_message: MISSING_SECRET_MESSAGE
      )
      endpoint.schedule_next_probe!
    end

    def expire_abandoned_probe
      abandoned = endpoint.circuit_probes.pending.where(created_at: ...(now - lease_duration))
      return if abandoned.empty?

      abandoned.update_all(
        status: 'failed',
        completed_at: now,
        error_type: CircuitProbe::LEASE_EXPIRED_ERROR_TYPE,
        error_message: CircuitProbe::LEASE_EXPIRED_MESSAGE,
        updated_at: now
      )
    end

    def finalize(claim, result)
      closed_circuit = false

      CircuitProbe.transaction do
        endpoint.with_lock do
          endpoint.reload

          record_result(claim.probe, result)
          closed_circuit = resolve_circuit(result) if owns_lease?(claim)
        end
      end

      Messages::ReleaseHeld.call(endpoint: endpoint) if closed_circuit
    end

    def owns_lease?(claim)
      endpoint.circuit_probe_lease_expires_at.present? &&
        endpoint.circuit_probe_lease_expires_at == claim.lease_expires_at
    end

    def record_result(probe, result)
      if result.error?
        probe.update!(
          status: :failed,
          completed_at: now,
          error_type: result.error_type,
          error_message: Webhooks::ResponseEvidence.truncate_error_message(result.error),
          duration_ms: result.duration_ms
        )
      else
        probe.update!(
          status: Webhooks::CircuitPolicy.success?(result) ? :succeeded : :failed,
          completed_at: now,
          response_status: result.status,
          response_headers: Webhooks::ResponseEvidence.filter_headers(result.headers),
          response_body: Webhooks::ResponseEvidence.truncate_response_body(result.body),
          duration_ms: result.duration_ms
        )
      end
    end

    def resolve_circuit(result)
      endpoint.release_probe_lease!

      if Webhooks::CircuitPolicy.success?(result)
        endpoint.close_circuit!
        true
      else
        resolve_probe_failure(result)
        false
      end
    end

    def resolve_probe_failure(result)
      endpoint.increment!(:circuit_failure_count) if Webhooks::CircuitPolicy.counted_failure?(result)

      if endpoint.disable_window_elapsed?
        endpoint.disable_circuit!
      else
        endpoint.schedule_next_probe!
      end
    end

    def lease_duration
      Webhooks::DeliveryPolicy.delivery_lease_duration
    end

    def now
      @now ||= Time.current
    end
  end
end
