require 'rails_helper'

describe Messages::BackfillCircuitQueueTrackingJob, type: :job do
  describe '#perform' do
    it 'delegates the backfill once to Messages::BackfillCircuitQueueTracking' do
      allow(Messages::BackfillCircuitQueueTracking).to receive(:call)

      expect(described_class.queue_name).to eq('low')

      described_class.perform_now

      expect(Messages::BackfillCircuitQueueTracking).to have_received(:call).once
    end
  end
end
