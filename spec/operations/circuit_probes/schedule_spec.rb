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

  describe '.call' do
    it 'enqueues a synthetic probe for the endpoints whose probe is due' do
      open_circuit(endpoint)

      described_class.call(now: now)

      expect(enqueued_probe_endpoint_ids).to eq([endpoint.id])
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
