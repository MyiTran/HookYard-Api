require 'rails_helper'

describe Replays::EnqueueDeliveries, type: :operation do
  let(:project) { create(:project) }
  let(:actor) { create(:user) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:run) { create(:replay_run, :bulk, project: project, actor: actor) }
  let(:job) { class_double(Replays::DeliverJob, perform_later: true) }
  let(:operation) { described_class.new(job: job) }

  def failed_message(target_endpoint = endpoint)
    create(:message, project: project, endpoint: target_endpoint, status: :failed)
  end

  describe '.call' do
    it 'enqueues the delivery of every queued item of the frozen set' do
      message = failed_message
      Replays::Snapshot.call(run: run)

      operation.call(run: run)

      item = run.replay_items.find_by(message_id: message.id)
      expect(job).to have_received(:perform_later).with(item.id)
      expect(run.reload.materialized_at).to be_present
    end

    it 'leaves held items to the circuit release flow' do
      failed_message(create(:endpoint, project: project, circuit_state: :circuit_open))
      Replays::Snapshot.call(run: run)

      operation.call(run: run)

      expect(job).not_to have_received(:perform_later)
      expect(run.replay_items.first.status).to eq(ReplayItem::HELD_STATUS)
    end

    it 'does not add a message that failed after the snapshot was taken' do
      create(:message, project: project, endpoint: endpoint, status: :failed)
      Replays::Snapshot.call(run: run)
      late = create(:message, project: project, endpoint: endpoint, status: :failed)

      operation.call(run: run)

      expect(run.replay_items.pluck(:message_id)).not_to include(late.id)
      expect(run.replay_items.count).to eq(1)
    end

    it 'is idempotent when the run was already dispatched' do
      failed_message
      Replays::Snapshot.call(run: run)
      operation.call(run: run)
      dispatched_at = run.reload.materialized_at

      expect { operation.call(run: run) }.not_to change(ReplayItem, :count)
      expect(job).to have_received(:perform_later).once
      expect(run.reload.materialized_at).to eq(dispatched_at)
    end

    it 'enqueues the queued items in bounded batches' do
      stub_const('Replays::EnqueueDeliveries::BATCH_SIZE', 2)
      create_list(:message, 5, project: project, endpoint: endpoint, status: :failed)
      Replays::Snapshot.call(run: run)

      operation.call(run: run)

      expect(job).to have_received(:perform_later).exactly(5).times
    end
  end
end
