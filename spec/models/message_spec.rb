require 'rails_helper'

describe Message, type: :model do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }

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
end
