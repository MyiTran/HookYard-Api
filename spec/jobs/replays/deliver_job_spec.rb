require 'rails_helper'

describe Replays::DeliverJob, type: :job do
  it 'is enqueued in the low queue' do
    expect { described_class.perform_later(SecureRandom.uuid) }
      .to have_enqueued_job(described_class).on_queue('low')
  end

  describe 'sidekiq options' do
    it 'uses a bounded idempotent retry for transient claim failures' do
      expect(described_class.sidekiq_options['retry']).to eq(5)
    end
  end

  describe '#perform' do
    it 'delegates the delivery to Replays::Deliver' do
      item = create(:replay_item)
      expect(Replays::Deliver).to receive(:call).with(item: item).once

      described_class.perform_now(item.id)
    end

    it 'discards a replay item that no longer exists' do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    end
  end
end
