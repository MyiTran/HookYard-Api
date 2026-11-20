require 'rails_helper'

describe CircuitProbes::RunJob, type: :job do
  describe 'sidekiq options' do
    it 'disables the automatic Sidekiq retry so the probe schedule owns the timing' do
      expect(described_class.sidekiq_options['retry']).to be(false)
    end
  end

  describe '#perform' do
    it 'runs the synthetic probe for the endpoint without a legacy reservation token' do
      endpoint = create(:endpoint)
      allow(CircuitProbes::Run).to receive(:call)

      described_class.new.perform(endpoint.id)

      expect(CircuitProbes::Run).to have_received(:call).with(endpoint: endpoint, reservation_token: nil)
    end

    it 'passes the reservation token from the scheduler to the probe owner' do
      endpoint = create(:endpoint)
      token = '2026-01-01T12:05:00.000000Z'
      allow(CircuitProbes::Run).to receive(:call)

      described_class.new.perform(endpoint.id, token)

      expect(CircuitProbes::Run).to have_received(:call).with(endpoint: endpoint, reservation_token: token)
    end

    it 'is discarded when the endpoint no longer exists' do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    end
  end
end
