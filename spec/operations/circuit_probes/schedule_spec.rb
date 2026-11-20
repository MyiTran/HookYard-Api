require 'rails_helper'

describe CircuitProbes::Schedule, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:now) { Time.zone.local(2026, 1, 1, 12, 0, 0) }

  before { travel_to(now) }

  def open_circuit(target_endpoint, next_probe_at: now, lease_expires_at: nil)
    target_endpoint.update!(
      circuit_state: 'circuit_open',
      circuit_failure_count: 5,
      circuit_opened_at: now,
      circuit_disable_at: now + 5.days,
      circuit_next_probe_at: next_probe_at,
      circuit_probe_lease_expires_at: lease_expires_at
    )
  end

  def enqueued_probe_endpoint_ids
    ActiveJob::Base.queue_adapter.enqueued_jobs
                        .select { |job| job[:job] == CircuitProbes::RunJob }
                        .map { |job| job[:args].first }
  end

  def enqueued_probe_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs
                        .select { |job| job[:job] == CircuitProbes::RunJob }
  end

  def http_result(status: 200)
    Webhooks::HttpClient::Result.new(status: status, headers: {}, body: 'ok', duration_ms: 1)
  end

  describe '.call' do
    it 'enqueues a synthetic probe for the endpoints whose probe is due' do
      open_circuit(endpoint)

      described_class.call(now: now)

      expect(enqueued_probe_endpoint_ids).to eq([endpoint.id])
    end

    it 'reserves the probe lease before enqueueing and passes the reservation token to the job' do
      open_circuit(endpoint)

      described_class.call(now: now)

      job = enqueued_probe_jobs.first
      endpoint.reload
      expect(endpoint.circuit_probe_lease_expires_at).to eq(now + Webhooks::DeliveryPolicy.delivery_lease_duration)
      expect(job[:args]).to eq([endpoint.id, endpoint.circuit_probe_lease_expires_at.utc.iso8601(6)])
    end

    it 'enqueues only one probe when repeated scheduler passes see the same due endpoint' do
      open_circuit(endpoint)

      19.times { described_class.call(now: now) }

      expect(enqueued_probe_jobs.size).to eq(1)
      expect(enqueued_probe_endpoint_ids).to eq([endpoint.id])
    end

    describe 'schedule to run integration' do
      let(:http_client) { double('http_client') }

      before do
        allow(Webhooks::HttpClient).to receive(:new).and_return(http_client)
        allow(http_client).to receive(:post).and_return(http_result)
      end

      it 'reserves, enqueues and runs exactly one probe with the reservation token' do
        open_circuit(endpoint)

        described_class.call(now: now)
        job = enqueued_probe_jobs.first
        endpoint_id, reservation_token = job[:args]

        expect(endpoint_id).to eq(endpoint.id)
        expect(reservation_token).to eq(endpoint.reload.circuit_probe_lease_expires_at.utc.iso8601(6))

        expect { CircuitProbes::RunJob.perform_now(endpoint_id, reservation_token) }
          .to change(CircuitProbe, :count).by(1)

        expect(http_client).to have_received(:post).once
        endpoint.reload
        expect(endpoint.circuit_probes.count).to eq(1)
        expect(endpoint).to be_enabled
        expect(endpoint.circuit_next_probe_at).to be_nil
        expect(endpoint.circuit_probe_lease_expires_at).to be_nil
      end

      it 'still enqueues only one job after 19 schedule passes' do
        open_circuit(endpoint)

        19.times { described_class.call(now: now) }

        expect(enqueued_probe_jobs.size).to eq(1)
      end
    end

    it 'releases the reservation when enqueueing the probe job fails' do
      open_circuit(endpoint)
      allow(CircuitProbes::RunJob).to receive(:perform_later).and_raise(Redis::CannotConnectError)

      expect { described_class.call(now: now) }.to raise_error(Redis::CannotConnectError)

      endpoint.reload
      expect(endpoint.circuit_probe_lease_expires_at).to be_nil
      expect(enqueued_probe_jobs).to be_empty
    end

    it 'can schedule again after the previous reservation expires' do
      open_circuit(endpoint)
      described_class.call(now: now)

      travel_to(now + Webhooks::DeliveryPolicy.delivery_lease_duration + 1.second)
      described_class.call(now: Time.current)

      expect(enqueued_probe_jobs.size).to eq(2)
      expect(enqueued_probe_endpoint_ids).to eq([endpoint.id, endpoint.id])
    end

    it 'does not enqueue a probe before the scheduled probe time' do
      open_circuit(endpoint, next_probe_at: now + 1.minute)

      described_class.call(now: now)

      expect(enqueued_probe_endpoint_ids).to be_empty
    end

    it 'does not enqueue a probe while another probe lease is active' do
      open_circuit(endpoint, lease_expires_at: now + 30.seconds)

      described_class.call(now: now)

      expect(enqueued_probe_endpoint_ids).to be_empty
    end

    it 'enqueues a probe when the previous lease already expired' do
      open_circuit(endpoint, lease_expires_at: now - 1.second)

      described_class.call(now: now)

      expect(enqueued_probe_endpoint_ids).to eq([endpoint.id])
    end

    it 'does not enqueue a probe for enabled or disabled endpoints' do
      open_circuit(create(:endpoint, project: project))
      create(:endpoint, project: project)
      create(:endpoint, project: project).disable_circuit!

      described_class.call(now: now)

      expect(enqueued_probe_endpoint_ids).to eq([Endpoint.circuit_open.first.id])
    end

    it 'probes an endpoint that has no pending messages' do
      open_circuit(endpoint)

      expect { described_class.call(now: now) }.not_to change(Message, :count)
      expect(enqueued_probe_endpoint_ids).to eq([endpoint.id])
    end
  end
end
