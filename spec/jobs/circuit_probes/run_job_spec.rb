require 'rails_helper'

describe CircuitProbes::RunJob, type: :job do
  describe 'sidekiq options' do
    it 'disables the automatic Sidekiq retry so the probe schedule owns the timing' do
      expect(described_class.sidekiq_options['retry']).to be(false)
    end
  end

  describe '#perform' do
    it 'runs the synthetic probe for the endpoint' do
      endpoint = create(:endpoint)
      allow(CircuitProbes::Run).to receive(:call)

      described_class.new.perform(endpoint.id)

      expect(CircuitProbes::Run).to have_received(:call).with(endpoint: endpoint)
    end

    it 'is discarded when the endpoint no longer exists' do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    end
  end
end
