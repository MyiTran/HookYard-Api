require 'rails_helper'

describe Replays::DeliverJob, type: :job do
  describe 'sidekiq options' do
    it 'runs replay deliveries on the low queue so live delivery keeps the default queue' do
      expect(described_class.new.queue_name).to eq('low')
    end

    it 'disables the automatic Sidekiq retry so the replay is never duplicated' do
      expect(described_class.sidekiq_options['retry']).to be(false)
    end
  end

  describe 'enqueueing' do
    it 'enqueues a replay delivery on the low queue' do
      item = create(:replay_item)

      described_class.perform_later(item.id)

      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.last).to include(job: described_class, queue: 'low')
    end
  end

  describe '#perform' do
    it 'delegates the replay to the operation' do
      item = create(:replay_item)
      allow(Replays::Deliver).to receive(:call)

      described_class.new.perform(item.id)

      expect(Replays::Deliver).to have_received(:call).with(item: item)
    end
  end
end
