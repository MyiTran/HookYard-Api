require 'rails_helper'

describe Replays::ReleaseHeld, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:run) { create(:replay_run, project: project) }
  let(:job) { class_double(Replays::DeliverJob, perform_later: nil) }
  let(:operation) { described_class.new(job: job) }

  def held_item
    create(:replay_item, replay_run: run, message: create(:message, project: project, endpoint: endpoint),
                         endpoint: endpoint, status: ReplayItem::HELD_STATUS,
                         hold_reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
  end

  describe '.call' do
    it 'releases held items and enqueues their deliveries' do
      items = Array.new(2) { held_item }

      operation.call(endpoint: endpoint)

      items.each(&:reload)
      expect(items.map(&:status)).to all(eq(ReplayItem::QUEUED_STATUS))
      expect(items.map(&:hold_reason)).to all(be_nil)
      expect(job).to have_received(:perform_later).with(items.first.id)
      expect(job).to have_received(:perform_later).with(items.second.id)
    end

    it 'leaves queued and terminal items untouched' do
      held = held_item
      queued = create(:replay_item, replay_run: run, message: create(:message, project: project, endpoint: endpoint),
                                    endpoint: endpoint, status: ReplayItem::QUEUED_STATUS)

      operation.call(endpoint: endpoint)

      expect(held.reload.status).to eq(ReplayItem::QUEUED_STATUS)
      expect(queued.reload.status).to eq(ReplayItem::QUEUED_STATUS)
    end

    it 'releases only items of the requested endpoint' do
      other_endpoint = create(:endpoint, project: project)
      other_item = create(:replay_item, replay_run: run,
                                        message: create(:message, project: project, endpoint: other_endpoint),
                                        endpoint: other_endpoint, status: ReplayItem::HELD_STATUS,
                                        hold_reason: ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
      held = held_item

      operation.call(endpoint: endpoint)

      expect(held.reload.status).to eq(ReplayItem::QUEUED_STATUS)
      expect(other_item.reload.status).to eq(ReplayItem::HELD_STATUS)
    end
  end
end
