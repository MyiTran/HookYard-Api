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
    it 'includes pending messages with no retry time or a retry time in the past' do
      fresh = new_message
      due = new_message(next_retry_at: 1.minute.ago)
      new_message(next_retry_at: 1.minute.from_now)
      new_message(status: :succeeded)

      expect(described_class.due_for_delivery).to contain_exactly(fresh, due)
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
