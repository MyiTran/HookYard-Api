require 'rails_helper'

describe Messages::BackfillCircuitQueueTrackingJob, type: :job do
  describe '#perform' do
    it 'delegates the backfill once to Messages::BackfillCircuitQueueTracking' do
      expect(Messages::BackfillCircuitQueueTracking).to receive(:call).once

      expect(described_class.queue_name).to eq('low')

      described_class.perform_now
    end
  end
end
