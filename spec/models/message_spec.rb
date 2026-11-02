require 'rails_helper'

describe Message, type: :model do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }
  let(:hold_reason) { Webhooks::CircuitPolicy::HOLD_REASONS[:circuit_open] }

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

    context 'when a message is held by the circuit' do
      it 'excludes the held message' do
        held = new_message(next_retry_at: 1.minute.ago)
        held.update_columns(held_at: Time.current, hold_reason: hold_reason)

        expect(described_class.due_for_delivery).to be_empty
      end
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

    context 'when a message is held by the circuit' do
      it 'excludes the held message' do
        held = new_message
        held.update_columns(updated_at: 2.hours.ago, held_at: Time.current, hold_reason: hold_reason)

        expect(described_class.pending_without_retry_before(1.hour.ago)).to be_empty
      end
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

  describe '#lease_active?' do
    it 'is true only while the lease expiry is in the future' do
      expect(build(:message, delivery_lease_expires_at: 1.minute.from_now).lease_active?).to be(true)
      expect(build(:message, delivery_lease_expires_at: 1.minute.ago).lease_active?).to be(false)
      expect(build(:message, delivery_lease_expires_at: nil).lease_active?).to be(false)
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

    context 'when the message is held by the circuit' do
      it 'releases the hold because the message is now delivering' do
        message.update_columns(held_at: Time.current, hold_reason: hold_reason)

        message.mark_delivering!(lease_expires_at: 1.minute.from_now, attempt_count: 1)

        expect(message.reload).not_to be_held
        expect(message.hold_reason).to be_nil
      end
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

  describe '#release_hold!' do
    context 'when the message is held' do
      it 'restores it as a plain pending message' do
        message.hold!(reason: hold_reason)

        message.release_hold!

        expect(message.reload).not_to be_held
        expect(message.hold_reason).to be_nil
      end
    end
  end

  describe '#delivery_state' do
    it 'reports the lifecycle state of the message' do
      expect(build(:message)).to have_attributes(delivery_state: Message::DELIVERY_STATE_QUEUED)
      expect(build(:message, next_retry_at: 1.minute.from_now).delivery_state)
        .to eq(Message::DELIVERY_STATE_SCHEDULED_RETRY)
      expect(build(:message, status: :delivering).delivery_state).to eq(Message::DELIVERY_STATE_DELIVERING)
      expect(build(:message, status: :failed).delivery_state).to eq(Message::DELIVERY_STATE_TERMINAL)
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
end
