require 'rails_helper'

describe Endpoints::ReEnable, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  def disabled_endpoint(**attributes)
    endpoint.tap do |record|
      record.update!(
        circuit_state: 'disabled',
        circuit_failure_count: 5,
        circuit_opened_at: 1.hour.ago,
        circuit_disable_at: 1.hour.ago + 5.days,
        **attributes
      )
    end
  end

  def open_endpoint
    endpoint.tap do |record|
      record.update!(
        circuit_state: 'circuit_open',
        circuit_failure_count: 5,
        circuit_opened_at: Time.current,
        circuit_disable_at: Time.current + 5.days,
        circuit_next_probe_at: Time.current,
        circuit_probe_lease_expires_at: Time.current
      )
    end
  end

  def held_message(reason: 'endpoint_circuit_open')
    create(:message, project: project, endpoint: endpoint).tap do |message|
      message.update_columns(held_at: Time.current, hold_reason: reason)
    end
  end

  def enqueued_message_ids
    ActiveJob::Base.queue_adapter.enqueued_jobs
                       .select { |job| job[:job] == Messages::DeliverJob }
                       .map { |job| job[:args].first }
  end

  describe '.call' do
    context 'when the endpoint circuit is disabled' do
      before { disabled_endpoint }

      it 'returns the endpoint to the enabled state and clears the tracking data' do
        described_class.call(endpoint: endpoint)

        endpoint.reload
        expect(endpoint).to be_enabled
        expect(endpoint.circuit_failure_count).to eq(0)
        expect(endpoint.circuit_opened_at).to be_nil
        expect(endpoint.circuit_disable_at).to be_nil
        expect(endpoint.circuit_next_probe_at).to be_nil
        expect(endpoint.circuit_probe_lease_expires_at).to be_nil
      end

      it 'releases the held messages and enqueues their delivery' do
        first = held_message(reason: 'endpoint_disabled')
        second = held_message(reason: 'endpoint_disabled')
        delivered = create(:message, project: project, endpoint: endpoint, status: :succeeded)

        described_class.call(endpoint: endpoint)

        expect([first.reload, second.reload]).to all(satisfy { |message| message.held_at.nil? })
        expect(delivered.reload.status).to eq('succeeded')
        expect(enqueued_message_ids).to contain_exactly(first.id, second.id)
      end

      it 'keeps the manual pause flag untouched' do
        disabled_endpoint(active: false)

        described_class.call(endpoint: endpoint)

        expect(endpoint.reload).to be_enabled
        expect(endpoint.active).to be(false)
      end
    end

    context 'when the endpoint circuit is open' do
      before { open_endpoint }

      it 'rejects the request without closing the circuit' do
        expect { described_class.call(endpoint: endpoint) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::CIRCUIT_OPEN_MESSAGE)

        endpoint.reload
        expect(endpoint).to be_circuit_open
        expect(endpoint.circuit_failure_count).to eq(5)
        expect(endpoint.circuit_opened_at).to be_present
        expect(endpoint.circuit_next_probe_at).to be_present
      end

      it 'keeps the held backlog and does not enqueue retries' do
        message = held_message

        expect { described_class.call(endpoint: endpoint) }.to raise_error(ApiError::UnprocessableEntityError)

        expect(message.reload.held_at).to be_present
        expect(message.hold_reason).to eq('endpoint_circuit_open')
        expect(enqueued_message_ids).to be_empty
      end

      it 'leaves the manual pause flag untouched' do
        endpoint.update!(active: false)

        expect { described_class.call(endpoint: endpoint) }.to raise_error(ApiError::UnprocessableEntityError)

        expect(endpoint.reload.active).to be(false)
      end
    end

    context 'when the endpoint is already enabled' do
      before { endpoint.update!(circuit_failure_count: 2) }

      it 'is an idempotent no-op' do
        described_class.call(endpoint: endpoint)

        expect(endpoint.reload).to be_enabled
        expect(endpoint.circuit_failure_count).to eq(2)
      end

      it 'keeps the normal retry schedule of a healthy endpoint' do
        retry_at = 5.minutes.from_now.change(usec: 0)
        scheduled = create(:message, project: project, endpoint: endpoint)
        scheduled.update_columns(next_retry_at: retry_at)

        described_class.call(endpoint: endpoint)

        expect(scheduled.reload.next_retry_at).to eq(retry_at)
        expect(enqueued_message_ids).to be_empty
      end

      it 'does not release or enqueue held messages' do
        message = held_message

        described_class.call(endpoint: endpoint)

        expect(message.reload.held_at).to be_present
        expect(enqueued_message_ids).to be_empty
      end
    end
  end
end
