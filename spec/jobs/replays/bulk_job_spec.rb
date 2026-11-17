require 'rails_helper'

describe Replays::BulkJob, type: :job do
  it 'is enqueued in the low queue' do
    expect { described_class.perform_later(SecureRandom.uuid) }
      .to have_enqueued_job(described_class).on_queue('low')
  end

  describe 'sidekiq options' do
    it 'uses a bounded idempotent retry for transient materialization failures' do
      expect(described_class.sidekiq_options['retry']).to eq(5)
    end
  end

  describe '#perform' do
    it 'delegates the materialization to Replays::EnqueueDeliveries' do
      run = create(:replay_run, mode: ReplayRun::MODE_BULK, materialized_at: nil)
      expect(Replays::EnqueueDeliveries).to receive(:call).with(run: run).once

      described_class.perform_now(run.id)
    end

    it 'discards a replay run that no longer exists' do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    end
  end
end
