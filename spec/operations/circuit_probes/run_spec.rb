require 'rails_helper'

describe CircuitProbes::Run, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:http_client) { double('http_client') }
  let(:signer) { Webhooks::Signer }
  let(:operation) { described_class.new(http_client: http_client, signer: signer) }
  let(:now) { Time.zone.local(2026, 1, 1, 12, 0, 0) }

  before { travel_to(now) }

  def http_result(status: 204, headers: {}, body: 'ok', error: nil, error_type: nil)
    Webhooks::HttpClient::Result.new(
      status: status,
      headers: headers,
      body: body,
      duration_ms: 12,
      error: error,
      error_type: error_type
    )
  end

  def open_circuit(disable_at: now + 5.days, next_probe_at: now)
    endpoint.update!(
      circuit_state: 'circuit_open',
      circuit_failure_count: 5,
      circuit_opened_at: now,
      circuit_disable_at: disable_at,
      circuit_next_probe_at: next_probe_at,
      circuit_probe_lease_expires_at: nil
    )
  end

  def held_message(created_at: now, reason: 'endpoint_circuit_open')
    create(:message, project: project, endpoint: endpoint).tap do |message|
      message.update_columns(held_at: created_at, hold_reason: reason, created_at: created_at)
    end
  end

  def enqueued_delivery_ids
    ActiveJob::Base.queue_adapter.enqueued_jobs
                       .select { |job| job[:job] == Messages::DeliverJob }
                       .map { |job| job[:args].first }
  end

  describe '.call' do
    context 'when the circuit is open and the probe is due' do
      before { open_circuit }

      it 'sends a signed synthetic health check instead of a business event' do
        captured = nil
        allow(http_client).to receive(:post) do |attributes|
          captured = attributes
          http_result
        end

        expect { operation.call(endpoint: endpoint) }.not_to change(Event, :count)
        expect(Message.count).to eq(0)

        payload = Oj.load(captured[:body])
        expect(captured[:url]).to eq(endpoint.url)
        expect(captured[:timeout]).to eq(Webhooks::DeliveryPolicy.timeout_seconds_for(project))
        expect(payload['type']).to eq('endpoint.test')
        expect(payload['id']).to eq(captured[:headers]['webhook-id'])
        expect(payload['id']).to start_with('probe_')
        expect(payload['created_at']).to eq(now.utc.iso8601)
        expect(payload['data']).to eq('endpoint_id' => endpoint.id, 'probe' => true)
        expect(captured[:headers]['webhook-request-id']).to start_with('probe_')
        expect(captured[:headers]['webhook-timestamp']).to eq(now.to_i.to_s)
      end

      it 'signs the probe with the current endpoint secret' do
        captured = nil
        allow(http_client).to receive(:post) do |attributes|
          captured = attributes
          http_result
        end

        operation.call(endpoint: endpoint)

        verified = signer.verify(
          secret: endpoint.current_signing_secret.secret,
          webhook_id: captured[:headers]['webhook-id'],
          timestamp: captured[:headers]['webhook-timestamp'],
          body: captured[:body],
          signature: captured[:headers]['webhook-signature']
        )

        expect(verified['type']).to eq('endpoint.test')
      end

      it 'records the probe evidence without touching messages or attempts' do
        message = held_message
        allow(http_client).to receive(:post).and_return(http_result(status: 200))

        expect { operation.call(endpoint: endpoint) }.to change(CircuitProbe, :count).by(1)

        expect(Message.count).to eq(1)
        expect(DeliveryAttempt.count).to eq(0)

        probe = endpoint.reload.last_circuit_probe
        expect(probe).to be_succeeded
        expect(probe.started_at).to eq(now)
        expect(probe.completed_at).to eq(now)
        expect(probe.response_status).to eq(200)
        expect(probe.duration_ms).to eq(12)
        expect(probe.signing_secret_version).to eq(endpoint.signing_secret_version)
        expect(probe.request_url).to eq(endpoint.url)
        expect(message.reload.attempt_count).to eq(0)
      end

      it 'filters sensitive response headers and keeps the stored body valid UTF-8' do
        allow(http_client).to receive(:post).and_return(
          http_result(status: 500, headers: { 'set-cookie' => 'session=1', 'x-trace' => 'abc' }, body: "bad\xFF".b)
        )

        operation.call(endpoint: endpoint)

        probe = endpoint.reload.last_circuit_probe
        expect(probe.response_headers).to eq('x-trace' => 'abc')
        expect(probe.response_body).to be_valid_encoding
      end

      it 'records a transport error as failed probe evidence' do
        allow(http_client).to receive(:post).and_return(
          http_result(status: nil, body: nil, error: 'execution expired', error_type: 'Net::ReadTimeout')
        )

        operation.call(endpoint: endpoint)

        probe = endpoint.reload.last_circuit_probe
        expect(probe).to be_failed
        expect(probe.error_type).to eq('Net::ReadTimeout')
        expect(probe.response_status).to be_nil
        expect(endpoint.reload).to be_circuit_open
      end

      it 'closes the circuit and releases held messages after a successful probe' do
        first = held_message
        second = held_message(created_at: now + 1.minute)
        allow(http_client).to receive(:post).and_return(http_result(status: 200))

        operation.call(endpoint: endpoint)

        endpoint.reload
        expect(endpoint).to be_enabled
        expect(endpoint.circuit_failure_count).to eq(0)
        expect(endpoint.circuit_opened_at).to be_nil
        expect(endpoint.circuit_disable_at).to be_nil
        expect(endpoint.circuit_next_probe_at).to be_nil
        expect(endpoint.circuit_probe_lease_expires_at).to be_nil
        expect(first.reload.held_at).to be_nil
        expect(second.reload.held_at).to be_nil
        expect(first.attempt_count).to eq(0)
        expect(enqueued_delivery_ids).to contain_exactly(first.id, second.id)
      end

      it 'releases and enqueues a backlog larger than the endpoint concurrency' do
        messages = Array.new(5) { held_message }
        allow(http_client).to receive(:post).and_return(http_result(status: 200))

        operation.call(endpoint: endpoint)

        expect(messages.map { |message| message.reload.held_at }).to all(be_nil)
        expect(enqueued_delivery_ids).to match_array(messages.map(&:id))
      end

      it 'recovers a pending message that lost its hold with a stale pre-circuit retry' do
        stranded = held_message
        stranded.update_columns(held_at: nil, hold_reason: nil, next_retry_at: now + 5.hours)
        allow(http_client).to receive(:post).and_return(http_result(status: 200))

        operation.call(endpoint: endpoint)

        stranded.reload
        expect(stranded.status).to eq('pending')
        expect(stranded.held_at).to be_nil
        expect(stranded.next_retry_at).to be_nil
        expect(enqueued_delivery_ids).to eq([stranded.id])
      end

      it 'leaves no pending message stranded after the recovery' do
        held_message
        held_message(created_at: now + 1.minute)
        allow(http_client).to receive(:post).and_return(http_result(status: 200))

        operation.call(endpoint: endpoint)

        endpoint.reload
        expect(endpoint).to be_enabled
        expect(endpoint.messages.pending.not_held.where(next_retry_at: nil).count).to eq(2)
        expect(enqueued_delivery_ids).to match_array(endpoint.messages.pluck(:id))
      end

      it 'keeps the circuit open and schedules the next probe after a failed probe' do
        Webhooks::DeliveryPolicy.jitter_source = -> { 0 }
        message = held_message
        allow(http_client).to receive(:post).and_return(http_result(status: 503))

        operation.call(endpoint: endpoint)

        endpoint.reload
        expect(endpoint).to be_circuit_open
        expect(endpoint.circuit_failure_count).to eq(6)
        expect(endpoint.circuit_disable_at).to eq(now + 5.days)
        expect(endpoint.circuit_probe_lease_expires_at).to be_nil
        expect(endpoint.circuit_next_probe_at).to eq(now + Webhooks::CircuitPolicy::PROBE_INTERVAL)
        expect(message.reload).to be_held
        expect(message.attempt_count).to eq(0)
        expect(enqueued_delivery_ids).to be_empty
      end

      it 'does not count a client error towards the failure streak' do
        allow(http_client).to receive(:post).and_return(http_result(status: 400))

        expect { operation.call(endpoint: endpoint) }
          .not_to(change { endpoint.reload.circuit_failure_count })
        expect(endpoint.reload).to be_circuit_open
      end

      it 'disables the endpoint when the probe fails after the persisted deadline' do
        open_circuit(disable_at: now - 1.second)
        message = held_message
        allow(http_client).to receive(:post).and_return(http_result(status: 500))

        operation.call(endpoint: endpoint)

        endpoint.reload
        expect(endpoint).to be_disabled
        expect(endpoint.circuit_next_probe_at).to be_nil
        expect(endpoint.circuit_probe_lease_expires_at).to be_nil
        expect(endpoint.circuit_disable_at).to eq(now - 1.second)
        expect(message.reload.hold_reason).to eq('endpoint_disabled')
        expect(message.attempt_count).to eq(0)
      end

      it 'still disables the endpoint when it has no pending messages' do
        open_circuit(disable_at: now - 1.second)
        allow(http_client).to receive(:post).and_return(http_result(status: 503))

        operation.call(endpoint: endpoint)

        expect(endpoint.reload).to be_disabled
        expect(Message.count).to eq(0)
      end

      it 'closes the circuit for an endpoint that never delivered a message' do
        allow(http_client).to receive(:post).and_return(http_result(status: 204))

        operation.call(endpoint: endpoint)

        expect(endpoint.reload).to be_enabled
        expect(Message.count).to eq(0)
        expect(enqueued_delivery_ids).to be_empty
      end
    end

    context 'when the endpoint has no current signing secret' do
      before do
        open_circuit
        endpoint.endpoint_signing_secrets.delete_all
      end

      it 'records a failed probe instead of sending an unsigned probe' do
        allow(http_client).to receive(:post)

        operation.call(endpoint: endpoint)

        expect(http_client).not_to have_received(:post)
        probe = endpoint.reload.last_circuit_probe
        expect(probe).to be_failed
        expect(probe.error_type).to eq(described_class::MISSING_SECRET_ERROR_TYPE)
        expect(probe.signing_secret_version).to be_nil
        expect(probe.response_status).to be_nil
        expect(endpoint).to be_circuit_open
      end
    end

    context 'when the circuit is not open' do
      it 'sends nothing for an enabled endpoint' do
        allow(http_client).to receive(:post)

        expect { operation.call(endpoint: endpoint) }.not_to change(CircuitProbe, :count)
        expect(http_client).not_to have_received(:post)
      end

      it 'sends nothing for a disabled endpoint' do
        endpoint.disable_circuit!
        allow(http_client).to receive(:post)

        expect { operation.call(endpoint: endpoint) }.not_to change(CircuitProbe, :count)
        expect(http_client).not_to have_received(:post)
        expect(endpoint.reload).to be_disabled
      end
    end

    context 'when the next probe is not due yet' do
      it 'sends nothing and keeps the schedule untouched' do
        open_circuit(next_probe_at: now + 1.minute)
        allow(http_client).to receive(:post)

        operation.call(endpoint: endpoint)

        expect(http_client).not_to have_received(:post)
        expect(endpoint.circuit_probes).to be_empty
        expect(endpoint.reload.circuit_next_probe_at).to eq(now + 1.minute)
      end
    end

    context 'when another probe is in flight' do
      it 'never runs a concurrent probe for the same endpoint' do
        open_circuit
        endpoint.update!(circuit_probe_lease_expires_at: now + 30.seconds)
        allow(http_client).to receive(:post)

        operation.call(endpoint: endpoint)

        expect(http_client).not_to have_received(:post)
        expect(endpoint.circuit_probes).to be_empty
        expect(endpoint.reload.circuit_probe_lease_expires_at).to eq(now + 30.seconds)
      end

      it 'ignores a duplicate job that runs while the first probe is sending' do
        open_circuit
        allow(http_client).to receive(:post) do
          described_class.new(http_client: http_client, signer: signer).call(endpoint: endpoint)
          http_result(status: 503)
        end

        operation.call(endpoint: endpoint)

        expect(http_client).to have_received(:post).once
        expect(endpoint.circuit_probes.count).to eq(1)
        expect(endpoint.reload.circuit_probe_lease_expires_at).to be_nil
      end
    end

    context 'when a previous probe was abandoned' do
      it 'fails the stale probe and runs the due probe again' do
        open_circuit
        stale = endpoint.circuit_probes.create!(
          request_id: 'probe_stale',
          webhook_id: 'probe_stale',
          signing_secret_version: 1,
          started_at: now - 10.minutes,
          request_url: endpoint.url,
          request_body: '{}'
        )
        stale.update_columns(created_at: now - 10.minutes)
        endpoint.update!(circuit_probe_lease_expires_at: now - 1.minute)
        allow(http_client).to receive(:post).and_return(http_result(status: 200))

        operation.call(endpoint: endpoint)

        stale.reload
        expect(stale).to be_failed
        expect(stale.error_type).to eq(CircuitProbe::LEASE_EXPIRED_ERROR_TYPE)
        expect(stale.completed_at).to eq(now)
        expect(http_client).to have_received(:post).once
        expect(endpoint.reload.circuit_probes.count).to eq(2)
      end
    end

    context 'when another worker took over the circuit while the probe was in flight' do
      it 'records the evidence but leaves the circuit to the new owner' do
        open_circuit
        taken_over_at = now + 10.seconds
        allow(http_client).to receive(:post) do
          endpoint.update_columns(
            circuit_state: 'circuit_open',
            circuit_probe_lease_expires_at: taken_over_at,
            circuit_next_probe_at: taken_over_at
          )
          http_result(status: 500)
        end

        operation.call(endpoint: endpoint)

        endpoint.reload
        expect(endpoint).to be_circuit_open
        expect(endpoint.circuit_failure_count).to eq(5)
        expect(endpoint.circuit_probe_lease_expires_at).to eq(taken_over_at)
        expect(endpoint.circuit_next_probe_at).to eq(taken_over_at)
        expect(endpoint.last_circuit_probe).to be_failed
      end
    end
  end
end
