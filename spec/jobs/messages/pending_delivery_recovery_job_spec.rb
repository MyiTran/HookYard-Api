require 'rails_helper'

describe Messages::PendingDeliveryRecoveryJob, type: :job do
  describe 'sidekiq options' do
    it 'disables the automatic Sidekiq retry so the recovery sweep owns the timing' do
      expect(described_class.sidekiq_options['retry']).to be(false)
    end
  end

  describe '#perform' do
    it 'recovers the deliveries that were never enqueued' do
      expect(Messages::EnqueuePending).to receive(:call).once

      described_class.new.perform
    end
  end
end
