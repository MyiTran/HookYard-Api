require 'rails_helper'

describe Messages::BackfillDeliveryRetryFieldsJob, type: :job do
  describe '#perform' do
    it 'delegates the backfill once to Messages::BackfillDeliveryRetryFields' do
      allow(Messages::BackfillDeliveryRetryFields).to receive(:call)

      expect(described_class.queue_name).to eq('low')

      described_class.perform_now

      expect(Messages::BackfillDeliveryRetryFields).to have_received(:call).once
    end
  end
end
