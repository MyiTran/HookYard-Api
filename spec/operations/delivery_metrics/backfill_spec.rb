require 'rails_helper'

describe DeliveryMetrics::Backfill, type: :operation do
  describe '.call' do
    it 'processes missing metrics in bounded batches until none remain' do
      allow(DeliveryMetric).to receive(:backfill_batch).and_return(2, 1, 0)

      expect(described_class.call(batch_size: 2)).to eq(3)
      expect(DeliveryMetric).to have_received(:backfill_batch).with(2).exactly(3).times
    end

    context 'with an invalid batch size' do
      it 'raises before claiming any delivery attempts' do
        allow(DeliveryMetric).to receive(:backfill_batch)

        expect { described_class.call(batch_size: 0) }
          .to raise_error(ArgumentError, 'batch_size must be a positive integer')

        expect(DeliveryMetric).not_to have_received(:backfill_batch)
      end
    end
  end
end
