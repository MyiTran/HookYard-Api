require 'rails_helper'

describe Messages::DeliverJob, type: :job do
  describe '.perform_later' do
    it 'is enqueued in the default queue' do
      expect { described_class.perform_later(SecureRandom.uuid) }
        .to have_enqueued_job(described_class).on_queue('default')
    end
  end

  describe '.perform_now' do
    it 'delegates delivery to Messages::Deliver' do
      message = create(:message)
      allow(Messages::Deliver).to receive(:call)

      described_class.perform_now(message.id)

      expect(Messages::Deliver).to have_received(:call).with(message: message)
    end

    it 'discards a message that no longer exists' do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    end
  end
end
