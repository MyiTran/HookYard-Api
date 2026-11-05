require 'rails_helper'

describe Replays::ReleaseHeld, type: :operation do
  let(:project) { create(:project) }
  let(:actor) { create(:user) }
  let(:endpoint) { create(:endpoint, project: project, circuit_state: :circuit_open) }
  let(:run) { create(:replay_run, project: project, actor: actor) }
  let(:job) { class_double(Replays::DeliverJob, perform_later: true) }
  let(:operation) { described_class.new(job: job) }

  def replay_item(status: ReplayItem::HELD_STATUS)
    message = create(:message, project: project, endpoint: endpoint, status: :failed)

    create(
      :replay_item,
      replay_run: run,
      message: message,
      endpoint: endpoint,
      status: status,
      hold_reason: status == ReplayItem::HELD_STATUS ? ReplayItem::HOLD_REASON_CIRCUIT_OPEN : nil
    )
  end

  describe '.call' do
    it 'queues the held items and enqueues their delivery' do
      item = replay_item

      operation.call(endpoint: endpoint)

      expect(item.reload.status).to eq(ReplayItem::QUEUED_STATUS)
      expect(item.hold_reason).to be_nil
      expect(job).to have_received(:perform_later).with(item.id)
    end

    it 'leaves terminal items untouched' do
      finished = replay_item(status: ReplayItem::SUCCEEDED_STATUS)
      finished.update!(completed_at: Time.current)

      operation.call(endpoint: endpoint)

      expect(finished.reload.status).to eq(ReplayItem::SUCCEEDED_STATUS)
      expect(job).not_to have_received(:perform_later)
    end

    it 'releases a backlog in bounded batches' do
      stub_const('Replays::ReleaseHeld::BATCH_SIZE', 1)
      items = [replay_item, replay_item]

      operation.call(endpoint: endpoint)

      expect(items.map { |item| item.reload.status }).to all(eq(ReplayItem::QUEUED_STATUS))
      expect(job).to have_received(:perform_later).twice
    end

    it 'does not release items of other endpoints' do
      other_endpoint = create(:endpoint, project: project, circuit_state: :circuit_open)
      other_message = create(:message, project: project, endpoint: other_endpoint, status: :failed)
      other_item = create(:replay_item, replay_run: run, message: other_message, endpoint: other_endpoint,
                                        status: ReplayItem::HELD_STATUS,
                                        hold_reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)

      operation.call(endpoint: endpoint)

      expect(other_item.reload.status).to eq(ReplayItem::HELD_STATUS)
    end
  end
end
