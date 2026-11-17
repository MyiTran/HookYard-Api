require 'rails_helper'

describe Replays::Snapshot, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project, event_type: 'order.created') }
  let(:run) do
    create(:replay_run, project: project, mode: ReplayRun::MODE_BULK,
                        materialized_at: nil, requested_count: 0)
  end
  let(:as_of) { Time.zone.local(2026, 1, 1, 12, 0, 0) }

  before { travel_to(as_of) }

  def failed_message(**attributes)
    create(:message, project: project, endpoint: endpoint, status: :failed, **attributes)
  end

  describe '.call' do
    it 'records the requested count and snapshots every eligible failed message' do
      messages = Array.new(3) { failed_message }

      described_class.call(run: run, as_of: as_of)

      expect(run.reload.requested_count).to eq(3)
      expect(run.replay_items.pluck(:message_id)).to match_array(messages.map(&:id))
      expect(run.replay_items.pluck(:status)).to all(eq(ReplayItem::QUEUED_STATUS))
    end

    it 'creates held items for circuit-open endpoints' do
      endpoint.update!(circuit_state: :circuit_open)
      failed_message

      described_class.call(run: run, as_of: as_of)

      item = run.replay_items.sole
      expect(item.status).to eq(ReplayItem::HELD_STATUS)
      expect(item.hold_reason).to eq(ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
    end

    it 'excludes failed messages of non-replayable endpoints' do
      endpoint.update!(archived_at: Time.current)
      failed_message

      described_class.call(run: run, as_of: as_of)

      expect(run.replay_items).to be_empty
    end

    it 'excludes held failed messages' do
      message = failed_message
      message.update_columns(held_at: Time.current, hold_reason: 'endpoint_circuit_open')

      described_class.call(run: run, as_of: as_of)

      expect(run.replay_items).to be_empty
    end

    it 'excludes messages that already have an active replay item' do
      message = failed_message
      create(:replay_item, message: message, endpoint: endpoint, status: ReplayItem::QUEUED_STATUS)

      described_class.call(run: run, as_of: as_of)

      expect(run.replay_items).to be_empty
    end

    it 'is idempotent across repeated snapshots of the same run' do
      failed_message

      described_class.call(run: run, as_of: as_of)
      described_class.call(run: run, as_of: as_of)

      expect(run.replay_items.count).to eq(1)
    end

    context 'when the eligible count exceeds the limit' do
      before { stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2) }

      it 'raises the bulk replay limit error without snapshotting items' do
        3.times { failed_message }

        expect { described_class.call(run: run, as_of: as_of) }
          .to raise_error(ApiError::BulkReplayLimitExceededError)
        expect(run.replay_items).to be_empty
      end
    end
  end
end
