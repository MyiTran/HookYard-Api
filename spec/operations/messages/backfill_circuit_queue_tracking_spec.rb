require 'rails_helper'

describe Messages::BackfillCircuitQueueTracking, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  def message(**attributes)
    create(:message, project: project, endpoint: endpoint, event: create(:event, project: project), **attributes)
  end

  def enqueued_job_classes
    ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }
  end

  def pending_message_without_slot(created_at:)
    message.tap { |record| record.update_columns(created_at: created_at, queued_at: nil) }
  end

  describe '.call' do
    context 'when a pending message predates queue tracking' do
      it 'backfills its queue slot from the created timestamp' do
        created_at = 3.days.ago.change(usec: 0)
        old_message = pending_message_without_slot(created_at: created_at)

        described_class.call

        expect(old_message.reload.queued_at).to eq(created_at)
      end
    end

    context 'when a delivering message predates queue tracking' do
      it 'backfills its queue slot' do
        created_at = 2.days.ago.change(usec: 0)
        in_flight = message(status: 'delivering', attempt_count: 1)
        in_flight.update_columns(created_at: created_at, queued_at: nil, delivery_lease_expires_at: 1.minute.from_now)

        described_class.call

        expect(in_flight.reload.queued_at).to eq(created_at)
      end
    end

    context 'when the message already owns a queue slot' do
      it 'never overwrites it' do
        queued_at = 1.hour.ago.change(usec: 0)
        tracked = message.tap { |record| record.update_columns(queued_at: queued_at) }

        described_class.call

        expect(tracked.reload.queued_at).to eq(queued_at)
      end
    end

    context 'when the message is already terminal' do
      it 'leaves it without a queue slot' do
        finished = message(status: 'succeeded')
        finished.update_columns(queued_at: nil, terminal_at: Time.current)

        described_class.call

        expect(finished.reload.queued_at).to be_nil
      end
    end

    context 'when the message is held by the circuit' do
      it 'keeps the hold untouched while backfilling the slot' do
        created_at = 4.days.ago.change(usec: 0)
        held = pending_message_without_slot(created_at: created_at)
        held.update_columns(held_at: created_at, hold_reason: 'endpoint_circuit_open')

        described_class.call

        held.reload
        expect(held.queued_at).to eq(created_at)
        expect(held.held_at).to eq(created_at)
        expect(held.hold_reason).to eq('endpoint_circuit_open')
      end
    end

    it 'does not touch updated_at' do
      old_message = pending_message_without_slot(created_at: 3.days.ago)
      updated_at = 2.days.ago.change(usec: 0)
      old_message.update_columns(updated_at: updated_at)

      described_class.call

      expect(old_message.reload.updated_at).to eq(updated_at)
    end

    context 'when the endpoint queue counter drifted' do
      it 'reconciles it from the backfilled slots' do
        pending_message_without_slot(created_at: 1.day.ago)
        endpoint.update_columns(queued_message_count: 7)

        described_class.call

        expect(endpoint.reload.queued_message_count).to eq(1)
      end
    end

    it 'reconciles every endpoint through Messages::ReconcileQueue' do
      other_endpoint = create(:endpoint, project: project)
      expect(Messages::ReconcileQueue).to receive(:call).with(endpoint: endpoint).once.and_call_original
      expect(Messages::ReconcileQueue).to receive(:call).with(endpoint: other_endpoint).once.and_call_original

      described_class.call
    end

    context 'when a message reached a terminal state without releasing its slot' do
      it 'releases the slot and clears the counter' do
        finished = message(status: 'succeeded')
        finished.update_columns(queued_at: 1.day.ago, terminal_at: Time.current)
        endpoint.update_columns(queued_message_count: 1)

        described_class.call

        expect(finished.reload.queued_at).to be_nil
        expect(endpoint.reload.queued_message_count).to eq(0)
      end
    end

    context 'when the backfill runs twice' do
      it 'is idempotent and reports nothing left to do' do
        pending_message_without_slot(created_at: 1.day.ago)

        first_run = described_class.call
        second_run = described_class.call

        expect(first_run[:queued_at_backfilled]).to eq(1)
        expect(second_run[:queued_at_backfilled]).to eq(0)
        expect(endpoint.reload.queued_message_count).to eq(1)
      end
    end

    context 'when circuit protection never persisted the disable deadline' do
      it 'backfills it from the open timestamp and the configured window' do
        opened_at = 2.days.ago.change(usec: 0)
        endpoint.update_columns(
          circuit_state: 'circuit_open',
          circuit_opened_at: opened_at,
          circuit_disable_at: nil,
          circuit_next_probe_at: opened_at
        )

        described_class.call

        expect(endpoint.reload.circuit_disable_at).to eq(opened_at + Webhooks::CircuitPolicy.disable_window)
      end

      it 'uses the configured window instead of a hard-coded one' do
        opened_at = 1.hour.ago.change(usec: 0)
        endpoint.update_columns(circuit_state: 'circuit_open', circuit_opened_at: opened_at, circuit_disable_at: nil)
        Webhooks::CircuitPolicy.disable_window = 10.minutes

        described_class.call

        expect(endpoint.reload.circuit_disable_at).to eq(opened_at + 10.minutes)
      end
    end

    it 'reports how much work it did' do
      pending_message_without_slot(created_at: 1.day.ago)

      expect(described_class.call).to include(
        messages_scanned: 1,
        queued_at_backfilled: 1,
        endpoints_reconciled: 1,
        circuit_disable_at_backfilled: 0
      )
    end

    it 'processes more than one keyset batch' do
      3.times { pending_message_without_slot(created_at: 1.day.ago) }

      expect(described_class.call(batch_size: 1)[:queued_at_backfilled]).to eq(3)
      expect(endpoint.reload.queued_message_count).to eq(3)
    end

    context 'when the batch size is not a positive integer' do
      it 'raises an argument error' do
        expect { described_class.call(batch_size: 0) }.to raise_error(ArgumentError)
        expect { described_class.call(batch_size: -5) }.to raise_error(ArgumentError)
        expect { described_class.call(batch_size: '10') }.to raise_error(ArgumentError)
      end
    end

    it 'never enqueues deliveries or records delivery attempts' do
      pending_message_without_slot(created_at: 1.day.ago)

      described_class.call

      expect(enqueued_job_classes).to be_empty
      expect(DeliveryAttempt.count).to eq(0)
    end

    it 'creates no messages, events or probes' do
      pending_message_without_slot(created_at: 1.day.ago)

      expect { described_class.call }.not_to change { [Message.count, Event.count, CircuitProbe.count] }
    end

    it 'preserves status, retry and attempt fields' do
      scheduled = message(next_retry_at: 5.minutes.from_now, attempt_count: 2)
      scheduled.update_columns(queued_at: nil, status: 'delivering', delivery_lease_expires_at: 1.minute.from_now)
      before_attributes = scheduled.reload.attributes.slice('status', 'next_retry_at', 'attempt_count',
                                                           'delivery_lease_expires_at')

      described_class.call

      expect(scheduled.reload.attributes.slice(*before_attributes.keys)).to eq(before_attributes)
    end
  end
end
