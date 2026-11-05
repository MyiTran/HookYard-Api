require 'rails_helper'

describe Replays::BulkJob, type: :job do
  describe 'sidekiq options' do
    it 'runs the bulk dispatch on the low queue' do
      expect(described_class.new.queue_name).to eq('low')
    end
  end

  describe 'enqueueing' do
    it 'enqueues the bulk dispatch on the low queue' do
      run = create(:replay_run, :bulk)

      described_class.perform_later(run.id)

      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.last).to include(job: described_class, queue: 'low')
    end
  end

  describe '#perform' do
    it 'delegates the dispatch of the frozen set to the operation' do
      run = create(:replay_run, :bulk)
      allow(Replays::EnqueueDeliveries).to receive(:call)

      described_class.new.perform(run.id)

      expect(Replays::EnqueueDeliveries).to have_received(:call).with(run: run)
    end
  end
end
