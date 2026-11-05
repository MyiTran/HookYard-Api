require 'rails_helper'

describe Replays::Snapshot, type: :operation do
  let(:project) { create(:project) }
  let(:actor) { create(:user) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:run) { create(:replay_run, :bulk, project: project, actor: actor) }

  def failed_message(target_endpoint = endpoint, event: nil)
    attributes = { project: project, endpoint: target_endpoint, status: :failed }
    attributes[:event] = event if event

    create(:message, **attributes)
  end

  describe '.call' do
    it 'creates one replay item per eligible failed message' do
      messages = [failed_message, failed_message]
      create(:message, project: project, endpoint: endpoint, status: :succeeded)

      described_class.call(run: run)

      expect(run.replay_items.pluck(:message_id)).to match_array(messages.map(&:id))
      expect(run.reload.requested_count).to eq(2)
    end

    it 'freezes the confirmed filter snapshot as the only selection source' do
      other_event = create(:event, project: project, event_type: 'order.paid')
      matching = failed_message(event: other_event)
      failed_message

      run.update!(filters: { 'event_type' => 'order.paid' })
      described_class.call(run: run)

      expect(run.replay_items.pluck(:message_id)).to eq([matching.id])
      expect(run.requested_count).to eq(1)
    end

    it 'holds the items of endpoints whose circuit is open' do
      failed_message(create(:endpoint, project: project, circuit_state: :circuit_open))

      described_class.call(run: run)

      item = run.replay_items.first
      expect(item.status).to eq(ReplayItem::HELD_STATUS)
      expect(item.hold_reason).to eq(ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
    end

    it 'reports messages of disabled endpoints as blocked without an item' do
      failed_message(create(:endpoint, project: project, circuit_state: :disabled))
      eligible = failed_message

      described_class.call(run: run)

      expect(run.replay_items.pluck(:message_id)).to eq([eligible.id])
      expect(run.reload.requested_count).to eq(2)
      expect(run.progress[:summary]).to include(requested: 2, eligible: 1, blocked: 1)
    end

    it 'reports messages of paused endpoints as blocked without an item' do
      paused_endpoint = create(:endpoint, project: project, active: false)
      failed_message(paused_endpoint)
      eligible = failed_message

      described_class.call(run: run)

      expect(run.replay_items.pluck(:message_id)).to eq([eligible.id])
      expect(run.reload.requested_count).to eq(2)
      expect(run.progress[:summary]).to include(requested: 2, eligible: 1, blocked: 1)
    end

    context 'when an endpoint is paused after preview but before snapshot confirmation' do
      it 'does not queue or snapshot stale candidate messages and reports them as blocked' do
        endpoint.update!(active: false)
        failed_message

        described_class.call(run: run)

        expect(run.replay_items.count).to eq(0)
        expect(run.reload.requested_count).to eq(1)
        expect(run.progress[:summary]).to include(requested: 1, eligible: 0, blocked: 1)
      end
    end

    it 'does not duplicate a message that already has an active replay' do
      message = failed_message
      create(:replay_item, message: message)

      described_class.call(run: run)

      expect(run.replay_items.count).to eq(0)
    end

    it 'inserts the candidates in bounded batches' do
      stub_const('Replays::Snapshot::BATCH_SIZE', 2)
      create_list(:message, 5, project: project, endpoint: endpoint, status: :failed)

      described_class.call(run: run)

      expect(run.replay_items.count).to eq(5)
      expect(run.reload.requested_count).to eq(5)
    end

    context 'when a message becomes failed after the confirmation cutoff' do
      it 'keeps it out of the run even across batch boundaries' do
        stub_const('Replays::Snapshot::BATCH_SIZE', 1)
        confirmed = failed_message
        pending_message = create(:message, project: project, endpoint: endpoint, status: :pending)
        cutoff = Time.current

        travel 1.minute do
          pending_message.update!(status: :failed)

          described_class.call(run: run, as_of: cutoff)

          expect(run.replay_items.pluck(:message_id)).to eq([confirmed.id])
          expect(run.reload.requested_count).to eq(1)
        end
      end

      it 'applies the same cutoff to the cap check' do
        stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 1)
        failed_message
        cutoff = Time.current

        travel 1.minute do
          create_list(:message, 3, project: project, endpoint: endpoint, status: :failed)

          expect { described_class.call(run: run, as_of: cutoff) }.not_to raise_error
          expect(run.replay_items.count).to eq(1)
        end
      end
    end

    context 'when the cap count under-reports the frozen set' do
      before do
        stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2)
        allow(ReplayCandidatesQuery).to receive(:count).and_return(0)
        create_list(:message, 3, project: project, endpoint: endpoint, status: :failed)
      end

      it 'rejects the oversized set instead of truncating it' do
        expect { described_class.call(run: run) }
          .to raise_error(ApiError::BulkReplayLimitExceededError) { |error| expect(error.eligible).to eq(3) }
        expect(ReplayItem.count).to eq(3)
      end
    end
  end
end
