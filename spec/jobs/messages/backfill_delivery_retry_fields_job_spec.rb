require 'rails_helper'

describe Messages::BackfillDeliveryRetryFieldsJob, type: :job do
  describe '.perform_later' do
    it 'is enqueued in the low queue' do
      expect { described_class.perform_later }
        .to have_enqueued_job(described_class).on_queue('low')
    end
  end

  describe '.perform_now' do
    it 'delegates the backfill to Messages::BackfillDeliveryRetryFields' do
      allow(Messages::BackfillDeliveryRetryFields).to receive(:call)

      described_class.perform_now

      expect(Messages::BackfillDeliveryRetryFields).to have_received(:call)
    end
  end
end
