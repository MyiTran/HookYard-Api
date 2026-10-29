require 'rails_helper'

describe Messages::DeliverJob, type: :job do
  describe 'sidekiq options' do
    it 'disables the automatic Sidekiq retry so the delivery policy owns the timing' do
      expect(described_class.sidekiq_options['retry']).to be(false)
    end
  end

  describe '#perform' do
    it 'delegates the delivery to the operation' do
      message = create(:message)
      allow(Messages::Deliver).to receive(:call)

      described_class.new.perform(message.id)

      expect(Messages::Deliver).to have_received(:call).with(message: message)
    end
  end
end
