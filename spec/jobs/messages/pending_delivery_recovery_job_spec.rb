require 'rails_helper'

describe Messages::PendingDeliveryRecoveryJob, type: :job do
  describe 'sidekiq options' do
    it 'disables the automatic Sidekiq retry so the recovery sweep owns the timing' do
      expect(described_class.sidekiq_options['retry']).to be(false)
    end
  end

  describe '#perform' do
    it 'recovers the deliveries that were never enqueued' do
      allow(Messages::EnqueuePending).to receive(:call)

      described_class.new.perform

      expect(Messages::EnqueuePending).to have_received(:call)
    end
  end
end
