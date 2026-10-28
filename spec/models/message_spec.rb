require 'rails_helper'

describe Message, type: :model do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }

  def new_message(**attributes)
    create(:message, project: project, endpoint: endpoint, **attributes)
  end

  describe 'validations' do
    context 'when the attempt count is negative' do
      it 'is invalid' do
        message.attempt_count = -1

        expect(message).not_to be_valid
        expect(message.errors[:attempt_count]).to be_present
      end
    end

    context 'when the event and endpoint belong to different projects' do
      it 'is invalid' do
        other_endpoint = create(:endpoint)
        message.endpoint = other_endpoint

        expect(message).not_to be_valid
        expect(message.errors[:base]).to be_present
      end
    end
  end

  describe '.due_for_delivery' do
    it 'includes pending messages whose retry time has passed' do
      due = new_message(next_retry_at: 1.minute.ago)
      new_message
      new_message(next_retry_at: 1.minute.from_now)
      new_message(status: :succeeded)

      expect(described_class.due_for_delivery).to contain_exactly(due)
    end
  end

  describe '.pending_without_retry_before' do
    it 'includes only pending messages that never had a retry time and are older than the cutoff' do
      stale = new_message
      stale.update_columns(updated_at: 2.hours.ago)
      new_message
      retry_waiting = new_message(next_retry_at: 1.minute.ago)
      retry_waiting.update_columns(updated_at: 2.hours.ago)

      expect(described_class.pending_without_retry_before(1.hour.ago)).to contain_exactly(stale)
    end
  end

  describe '.with_expired_lease' do
    it 'includes delivering messages without an active lease' do
      expired = new_message
      expired.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.ago)
      missing = new_message
      missing.update_columns(status: 'delivering', delivery_lease_expires_at: nil)
      active = new_message
      active.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.from_now)

      expect(described_class.with_expired_lease).to contain_exactly(expired, missing)
    end
  end

  describe '.with_active_lease' do
    it 'includes only delivering messages whose lease has not expired' do
      active = new_message
      active.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.from_now)
      expired = new_message
      expired.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.ago)
      new_message

      expect(described_class.with_active_lease).to contain_exactly(active)
    end
  end

  describe '.held_by_circuit' do
    it 'includes pending messages held by an open or disabled circuit' do
      open_circuit = new_message
      open_circuit.hold!(reason: 'endpoint_circuit_open')
      disabled = new_message
      disabled.hold!(reason: 'endpoint_disabled')

      expect(described_class.held_by_circuit).to contain_exactly(open_circuit, disabled)
    end

    it 'excludes every other delivery state' do
      new_message
      new_message(next_retry_at: 1.minute.from_now)
      new_message(status: :succeeded, terminal_at: Time.current)

      expect(described_class.held_by_circuit).to be_empty
    end
  end

  describe '#terminal?' do
    it 'is only true for succeeded and failed messages' do
      expect(build(:message, status: :pending).terminal?).to be(false)
      expect(build(:message, status: :delivering).terminal?).to be(false)
      expect(build(:message, status: :succeeded).terminal?).to be(true)
      expect(build(:message, status: :failed).terminal?).to be(true)
    end
  end

  describe '#retries_available?' do
    it 'is true while fewer than the maximum attempts were made' do
      message.attempt_count = Webhooks::DeliveryPolicy::MAX_ATTEMPTS - 1
      expect(message.retries_available?).to be(true)

      message.attempt_count = Webhooks::DeliveryPolicy::MAX_ATTEMPTS
      expect(message.retries_available?).to be(false)
    end
  end

  describe '#lease_expired?' do
    it 'is true for a delivering message with an expired or missing lease' do
      message.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.ago)
      expect(message.reload.lease_expired?).to be(true)

      message.update_columns(delivery_lease_expires_at: nil)
      expect(message.reload.lease_expired?).to be(true)
    end

    it 'is false while the lease is active' do
      message.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.from_now)

      expect(message.reload.lease_expired?).to be(false)
    end
  end

  describe '#mark_succeeded!' do
    it 'stores the terminal state and releases the lease' do
      message.update_columns(status: 'delivering', attempt_count: 1, delivery_lease_expires_at: 1.minute.from_now)

      message.mark_succeeded!

      expect(message.reload.status).to eq('succeeded')
      expect(message.terminal_at).to be_present
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
    end

    it 'decrements the endpoint queue count exactly once when the message becomes terminal' do
      endpoint.update!(queued_message_count: 1)
      message.update_columns(queued_at: Time.current)

      message.mark_succeeded!
      message.mark_failed!

      expect(endpoint.reload.queued_message_count).to eq(0)
    end

    it 'does not decrement the queue count for a message that was never counted' do
      endpoint.update!(queued_message_count: 0)

      message.mark_succeeded!

      expect(endpoint.reload.queued_message_count).to eq(0)
    end

    context 'when the message was held by the circuit before being delivered' do
      it 'clears the hold tracking together with the terminal state' do
        message.hold!(reason: 'endpoint_circuit_open')
        message.mark_delivering!(lease_expires_at: 1.minute.from_now, attempt_count: 1)

        message.mark_succeeded!

        message.reload
        expect(message).to be_succeeded
        expect(message.held_at).to be_nil
        expect(message.hold_reason).to be_nil
        expect(message.delivery_state).to eq('terminal')
      end

      it 'stops reporting the hold as soon as the delivery starts' do
        message.hold!(reason: 'endpoint_circuit_open')

        message.mark_delivering!(lease_expires_at: 1.minute.from_now, attempt_count: 1)

        message.reload
        expect(message.held_at).to be_nil
        expect(message.hold_reason).to be_nil
        expect(message.delivery_state).to eq('delivering')
      end
    end

    it 'cannot keep circuit hold fields on a terminal message' do
      message.mark_succeeded!

      expect do
        message.update_columns(held_at: Time.current, hold_reason: 'endpoint_circuit_open')
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe '#schedule_retry!' do
    it 'returns the message to pending without a terminal timestamp' do
      message.update_columns(status: 'delivering', attempt_count: 1, delivery_lease_expires_at: 1.minute.from_now)
      retry_at = 5.minutes.from_now

      message.schedule_retry!(at: retry_at)

      expect(message.reload.status).to eq('pending')
      expect(message.next_retry_at).to eq(retry_at)
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.terminal_at).to be_nil
    end
  end

  describe '#delivery_state' do
    it 'describes every observable delivery state' do
      expect(build(:message, status: :pending).delivery_state).to eq('queued')
      expect(build(:message, status: :pending, next_retry_at: 1.minute.from_now).delivery_state).to eq('scheduled_retry')
      expect(build(:message, status: :pending, held_at: Time.current).delivery_state).to eq('held_by_circuit')
      expect(build(:message, status: :delivering).delivery_state).to eq('delivering')
      expect(build(:message, status: :succeeded).delivery_state).to eq('terminal')
      expect(build(:message, status: :failed).delivery_state).to eq('terminal')
    end
  end

  describe '#hold_summary' do
    it 'is nil while the message is not held' do
      expect(build(:message).hold_summary).to be_nil
    end

    it 'describes the hold reason and start time' do
      held_at = Time.zone.local(2026, 1, 1, 12, 0, 0)
      message = build(:message, held_at: held_at, hold_reason: 'endpoint_circuit_open')

      expect(message.hold_summary).to eq(reason: 'endpoint_circuit_open', since: held_at, release_at: nil)
    end
  end

  describe '#hold!' do
    it 'parks the message without a retry schedule' do
      message.update_columns(next_retry_at: 1.minute.from_now)

      message.hold!(reason: 'endpoint_disabled')

      message.reload
      expect(message).to be_held
      expect(message.hold_reason).to eq('endpoint_disabled')
      expect(message.next_retry_at).to be_nil
      expect(message.attempt_count).to eq(0)
    end
  end

  describe '#mark_failed!' do
    it 'decrements the endpoint queue count exactly once' do
      endpoint.update!(queued_message_count: 2)
      message.update_columns(queued_at: Time.current)

      message.mark_failed!
      message.mark_failed!

      expect(endpoint.reload.queued_message_count).to eq(1)
    end

    it 'clears the hold tracking of a held message that finally fails' do
      message.hold!(reason: 'endpoint_disabled')
      message.mark_delivering!(lease_expires_at: 1.minute.from_now, attempt_count: Webhooks::DeliveryPolicy::MAX_ATTEMPTS)

      message.mark_failed!

      message.reload
      expect(message).to be_failed
      expect(message.held_at).to be_nil
      expect(message.hold_reason).to be_nil
      expect(message.delivery_state).to eq('terminal')
    end

    it 'cannot keep circuit hold fields on a failed message' do
      message.mark_failed!

      expect do
        message.update_columns(held_at: Time.current, hold_reason: 'endpoint_disabled')
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe 'concurrent terminal transitions' do
    self.use_transactional_tests = false

    after { project.destroy! }

    it 'releases the queue slot of a message exactly once' do
      target = create(:message, project: project, endpoint: endpoint)
      target.update_columns(queued_at: Time.current)
      endpoint.update_columns(queued_message_count: 1)
      start = Queue.new

      threads = Array.new(4) do
        Thread.new do
          start.pop
          ActiveRecord::Base.connection_pool.with_connection do
            described_class.find(target.id).mark_succeeded!
          end
        end
      end

      4.times { start.push(true) }
      threads.each(&:join)

      expect(endpoint.reload.queued_message_count).to eq(0)
      expect(target.reload.status).to eq('succeeded')
    end
  end
end
