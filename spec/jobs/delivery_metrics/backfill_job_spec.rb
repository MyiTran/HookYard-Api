require 'rails_helper'

describe DeliveryMetrics::BackfillJob, type: :job do
  describe '#perform' do
    it 'delegates the backfill to the low-priority operation' do
      allow(DeliveryMetrics::Backfill).to receive(:call)

      described_class.perform_now

      expect(described_class.queue_name).to eq('low')
      expect(DeliveryMetrics::Backfill).to have_received(:call).once
    end
  end
end
