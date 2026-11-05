require 'rails_helper'

describe ReplayItem, type: :model do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:message) { create(:message, project: project, endpoint: endpoint, status: :failed) }
  let(:run) { create(:replay_run, project: project) }

  def build_item(status:, message_record: message)
    build(:replay_item, replay_run: run, message: message_record, endpoint: message_record.endpoint, status: status)
  end

  describe 'validations' do
    context 'when the item endpoint differs from the message endpoint' do
      it 'is invalid' do
        item = build(:replay_item, replay_run: run, message: message, endpoint: create(:endpoint, project: project))

        expect(item).not_to be_valid
      end
    end

    context 'when the hold reason is not a known circuit hold' do
      it 'is invalid' do
        item = build_item(status: ReplayItem::HELD_STATUS)
        item.hold_reason = 'something_else'

        expect(item).not_to be_valid
      end
    end

    context 'when the skip reason is not a known skip' do
      it 'is invalid' do
        item = build_item(status: ReplayItem::SKIPPED_STATUS)
        item.skip_reason = 'something_else'

        expect(item).not_to be_valid
      end
    end

    context 'when the skip reason is a known skip' do
      it 'is valid' do
        ReplayItem::SKIP_REASONS.each do |reason|
          item = build_item(status: ReplayItem::SKIPPED_STATUS)
          item.skip_reason = reason

          expect(item).to be_valid
        end
      end
    end
  end

  describe 'audit reasons' do
    context 'when a held item has no hold reason' do
      it 'is invalid' do
        item = build_item(status: ReplayItem::HELD_STATUS)

        expect(item).not_to be_valid
        expect(item.errors[:hold_reason]).to be_present
      end
    end

    context 'when a held item keeps the circuit hold reason' do
      it 'is valid' do
        item = build_item(status: ReplayItem::HELD_STATUS)
        item.hold_reason = ReplayItem::HOLD_REASON_CIRCUIT_OPEN

        expect(item).to be_valid
      end
    end

    context 'when a queued item still carries a hold reason' do
      it 'is invalid' do
        item = build_item(status: ReplayItem::QUEUED_STATUS)
        item.hold_reason = ReplayItem::HOLD_REASON_CIRCUIT_OPEN

        expect(item).not_to be_valid
        expect(item.errors[:hold_reason]).to be_present
      end
    end

    context 'when a skipped item has no skip reason' do
      it 'is invalid' do
        item = build_item(status: ReplayItem::SKIPPED_STATUS)

        expect(item).not_to be_valid
        expect(item.errors[:skip_reason]).to be_present
      end
    end

    context 'when a failed item still carries a skip reason' do
      it 'is invalid' do
        item = build_item(status: ReplayItem::FAILED_STATUS)
        item.skip_reason = ReplayItem::SKIP_REASON_ENDPOINT_ARCHIVED

        expect(item).not_to be_valid
        expect(item.errors[:skip_reason]).to be_present
      end
    end
  end

  describe 'status transitions' do
    it 'drops the skip reason when the item is held again' do
      item = create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                                  status: ReplayItem::SKIPPED_STATUS,
                                  skip_reason: ReplayItem::SKIP_REASON_ENDPOINT_PAUSED, completed_at: Time.current)

      item.mark_held!(reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)

      expect(item.reload.hold_reason).to eq(ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
      expect(item.skip_reason).to be_nil
    end

    it 'drops the hold reason when the item is skipped' do
      item = create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                                  status: ReplayItem::HELD_STATUS,
                                  hold_reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)

      item.mark_skipped!(reason: ReplayItem::SKIP_REASON_ENDPOINT_ARCHIVED)

      expect(item.reload.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_ARCHIVED)
      expect(item.hold_reason).to be_nil
    end

    it 'drops both reasons when the item is queued again' do
      item = create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                                  status: ReplayItem::SKIPPED_STATUS,
                                  skip_reason: ReplayItem::SKIP_REASON_ENDPOINT_PAUSED, completed_at: Time.current)

      item.mark_queued!

      expect(item.reload.status).to eq(ReplayItem::QUEUED_STATUS)
      expect(item.hold_reason).to be_nil
      expect(item.skip_reason).to be_nil
    end

    it 'drops the hold reason when the item starts delivering' do
      item = create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                                  status: ReplayItem::HELD_STATUS,
                                  hold_reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)

      item.mark_delivering!(lease_expires_at: 30.seconds.from_now)

      expect(item.reload.status).to eq(ReplayItem::DELIVERING_STATUS)
      expect(item.hold_reason).to be_nil
      expect(item.skip_reason).to be_nil
    end

    it 'drops the hold reason when the item succeeds' do
      item = create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                                  status: ReplayItem::HELD_STATUS,
                                  hold_reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)

      item.mark_succeeded!

      expect(item.reload.status).to eq(ReplayItem::SUCCEEDED_STATUS)
      expect(item.hold_reason).to be_nil
      expect(item.skip_reason).to be_nil
    end

    it 'drops the hold reason when the item fails' do
      item = create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                                  status: ReplayItem::HELD_STATUS,
                                  hold_reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)

      item.mark_failed!(error_type: 'Net::ReadTimeout', error_message: 'execution expired')

      expect(item.reload.status).to eq(ReplayItem::FAILED_STATUS)
      expect(item.hold_reason).to be_nil
      expect(item.skip_reason).to be_nil
    end
  end

  describe 'active replay uniqueness' do
    it 'rejects a second active replay for the same message' do
      create(:replay_item, replay_run: run, message: message, endpoint: endpoint)
      duplicate = build(:replay_item, replay_run: run, message: message, endpoint: endpoint)

      expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows a new replay after the previous item finished' do
      create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                           status: ReplayItem::SUCCEEDED_STATUS, completed_at: Time.current)
      item = build(:replay_item, replay_run: run, message: message, endpoint: endpoint)

      expect(item).to be_valid
      expect { item.save! }.not_to raise_error
    end
  end

  describe '#lease_active?' do
    it 'is true only while the replay delivery lease is valid' do
      item = build_item(status: ReplayItem::DELIVERING_STATUS)
      item.delivery_lease_expires_at = 30.seconds.from_now

      expect(item.lease_active?).to be(true)
      expect(item.lease_active?(31.seconds.from_now)).to be(false)
    end
  end
end
