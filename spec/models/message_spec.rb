require 'rails_helper'

describe Message, type: :model do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }
  let(:hold_reason) { 'endpoint_disabled' }

  def new_message(**attributes)
    create(:message, project: project, endpoint: endpoint, **attributes)
  end

  describe 'status constraint' do
    context 'when an unknown status is written' do
      it 'is rejected by the database' do
        expect { create(:message).update_column(:status, 'unknown') }
          .to raise_error(ActiveRecord::StatementInvalid)
      end
    end
  end

  describe '#webhook_id' do
    it 'stays stable for the message' do
      expect(message.webhook_id).to eq("msg_#{message.id}")
      expect(message.webhook_id).to eq(message.reload.webhook_id)
    end
  end

  describe 'validations' do
    context 'with the default factory' do
      it 'is valid' do
        expect(build(:message)).to be_valid
      end
    end

    context 'when the endpoint belongs to a different project than the event' do
      it 'is invalid' do
        invalid_message = build(:message, event: create(:event), endpoint: create(:endpoint))

        expect(invalid_message).not_to be_valid
        expect(invalid_message.errors[:base]).to be_present
      end
    end

    context 'when the attempt count is negative' do
      it 'is invalid' do
        message.attempt_count = -1

        expect(message).not_to be_valid
        expect(message.errors[:attempt_count]).to be_present
      end
    end

    context 'when the message carries no hold' do
      it 'accepts a nil hold reason' do
        expect(build(:message, held_at: nil, hold_reason: nil)).to be_valid
      end
    end

    context 'when the message is held by the circuit' do
      it 'accepts every hold reason the circuit can produce' do
        Webhooks::CircuitPolicy::HOLD_REASONS.each_value do |reason|
          held_message = build(:message, status: :pending, held_at: Time.current, hold_reason: reason)

          expect(held_message).to be_valid, "#{reason} must be a valid hold reason"
        end
      end

      it 'rejects a hold reason the circuit cannot produce' do
        held_message = build(:message, status: :pending, held_at: Time.current, hold_reason: 'manual_review')

        expect(held_message).not_to be_valid
        expect(held_message.errors[:hold_reason]).to be_present
      end

      it 'requires a hold reason' do
        held_message = build(:message, status: :pending, held_at: Time.current, hold_reason: nil)

        expect(held_message).not_to be_valid
        expect(held_message.errors[:hold_reason]).to be_present
      end

      it 'refuses to hold a message that is no longer pending' do
        held_message = build(:message, status: :delivering, held_at: Time.current, hold_reason: hold_reason)

        expect(held_message).not_to be_valid
        expect(held_message.errors[:status]).to be_present
      end
    end

    context 'when a hold reason survived on a message that is not held' do
      it 'is invalid' do
        stale_message = build(:message, status: :pending, held_at: nil, hold_reason: hold_reason)

        expect(stale_message).not_to be_valid
        expect(stale_message.errors[:held_at]).to be_present
      end
    end
  end

  describe 'delivery target uniqueness' do
    it 'allows only one message per event and endpoint' do
      create(:message, event: event, endpoint: endpoint)

      expect { create(:message, event: event, endpoint: endpoint) }
        .to raise_error(ActiveRecord::RecordNotUnique)
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

  describe '#terminal?' do
    it 'is only true for succeeded and failed messages' do
      expect(build(:message, status: :pending).terminal?).to be(false)
      expect(build(:message, status: :delivering).terminal?).to be(false)
      expect(build(:message, status: :succeeded).terminal?).to be(true)
      expect(build(:message, status: :failed).terminal?).to be(true)
    end
  end

  describe '#retryable?' do
    it 'is true for a pending message with attempts left' do
      expect(build(:message, status: :pending, attempt_count: 1)).to be_retryable
    end

    it 'is false once every attempt has been used' do
      expect(build(:message, status: :pending, attempt_count: Webhooks::DeliveryPolicy::MAX_ATTEMPTS))
        .not_to be_retryable
    end

    it 'is false for a terminal message' do
      expect(build(:message, status: :succeeded)).not_to be_retryable
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

  describe '#lease_active?' do
    it 'is true only while the lease expiry is in the future' do
      expect(build(:message, delivery_lease_expires_at: 1.minute.from_now).lease_active?).to be(true)
      expect(build(:message, delivery_lease_expires_at: 1.minute.ago).lease_active?).to be(false)
      expect(build(:message, delivery_lease_expires_at: nil).lease_active?).to be(false)
    end
  end

  describe '#mark_delivering!' do
    it 'claims the message with a lease and clears the retry schedule' do
      message.update_columns(next_retry_at: 1.minute.from_now, terminal_at: 1.minute.ago)
      lease_expires_at = 1.minute.from_now

      message.mark_delivering!(lease_expires_at: lease_expires_at, attempt_count: 2)

      expect(message.reload.status).to eq('delivering')
      expect(message.attempt_count).to eq(2)
      expect(message.delivery_lease_expires_at).to eq(lease_expires_at)
      expect(message.next_retry_at).to be_nil
      expect(message.terminal_at).to be_nil
    end
  end

  describe '#mark_failed!' do
    it 'stores the terminal state and releases the lease' do
      message.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.from_now)
      failed_at = Time.current

      message.mark_failed!(at: failed_at)

      expect(message.reload.status).to eq('failed')
      expect(message).to be_terminal
      expect(message.terminal_at).to eq(failed_at)
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
    end

    context 'when the message owned a circuit queue slot' do
      it 'clears the slot and decrements the endpoint queue counter' do
        message.update_columns(queued_at: Time.current, status: 'delivering')
        endpoint.update_columns(queued_message_count: 1)

        message.mark_failed!

        expect(message.reload.queued_at).to be_nil
        expect(message).not_to be_queue_counted
        expect(endpoint.reload.queued_message_count).to eq(0)
      end

      it 'decrements the endpoint queue count exactly once' do
        endpoint.update!(queued_message_count: 2)
        message.update_columns(queued_at: Time.current)

        message.mark_failed!
        message.mark_failed!

        expect(endpoint.reload.queued_message_count).to eq(1)
      end
    end

    context 'when the message was held' do
      it 'clears the hold tracking of a message that finally fails' do
        message.hold!(reason: 'endpoint_disabled')
        message.mark_delivering!(lease_expires_at: 1.minute.from_now,
                                 attempt_count: Webhooks::DeliveryPolicy::MAX_ATTEMPTS)

        message.mark_failed!

        message.reload
        expect(message).to be_failed
        expect(message.held_at).to be_nil
        expect(message.hold_reason).to be_nil
        expect(message.delivery_state).to eq(Message::DELIVERY_STATE_TERMINAL)
      end
    end

    context 'when circuit hold fields are written to a failed message' do
      it 'is rejected by the model' do
        message.mark_failed!
        message.assign_attributes(held_at: Time.current, hold_reason: 'endpoint_disabled')

        expect(message).not_to be_valid
        expect(message.errors[:status]).to be_present
      end
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

  describe '#hold!' do
    it 'parks the message as held and clears the retry schedule' do
      message.update_columns(next_retry_at: 1.minute.from_now, delivery_lease_expires_at: 1.minute.from_now)
      held_at = Time.current

      message.hold!(reason: hold_reason, at: held_at)

      expect(message.reload).to be_held
      expect(message.held_at).to eq(held_at)
      expect(message.hold_reason).to eq(hold_reason)
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.delivery_state).to eq(Message::DELIVERY_STATE_HELD)
    end
  end

  describe 'hold release' do
    it 'has no single-record release helper; holds are released in bulk' do
      expect(described_class.method_defined?(:release_hold!)).to be(false)
    end
  end

  describe '#delivery_state' do
    it 'describes every observable delivery state' do
      expect(build(:message, status: :pending).delivery_state).to eq(Message::DELIVERY_STATE_QUEUED)
      expect(build(:message, status: :pending, next_retry_at: 1.minute.from_now).delivery_state)
        .to eq(Message::DELIVERY_STATE_SCHEDULED_RETRY)
      expect(build(:message, status: :pending, held_at: Time.current).delivery_state)
        .to eq(Message::DELIVERY_STATE_HELD)
      expect(build(:message, status: :delivering).delivery_state).to eq(Message::DELIVERY_STATE_DELIVERING)
      expect(build(:message, status: :succeeded).delivery_state).to eq(Message::DELIVERY_STATE_TERMINAL)
      expect(build(:message, status: :failed).delivery_state).to eq(Message::DELIVERY_STATE_TERMINAL)
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

  describe '.delivery_state_scope' do
    it 'returns the circuit held scope and nothing for unknown states' do
      held = new_message
      held.update_columns(held_at: Time.current, hold_reason: hold_reason)

      expect(described_class.delivery_state_scope('held_by_circuit')).to contain_exactly(held)
      expect(described_class.delivery_state_scope('unknown')).to be_nil
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
