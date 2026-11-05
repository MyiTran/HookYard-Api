require 'rails_helper'

describe CircuitProbe, type: :model do
  let(:endpoint) { create(:endpoint) }
  let(:probe) { create(:circuit_probe, endpoint: endpoint) }

  describe 'validations' do
    context 'when the request evidence is rewritten' do
      it 'refuses the change' do
        probe.request_url = 'https://attacker.example/hooks'

        expect(probe).not_to be_valid
        expect(probe.errors[:base]).to be_present
      end
    end

    context 'when only the result is recorded' do
      it 'accepts the completion fields' do
        probe.assign_attributes(
          status: :failed,
          completed_at: Time.current,
          response_status: 500,
          duration_ms: 12
        )

        expect(probe).to be_valid
      end
    end

    context 'when a probe is recorded without a signing secret version' do
      it 'accepts the new record so the missing secret is recorded instead of skipped' do
        failed_probe = build(:circuit_probe, endpoint: endpoint, signing_secret_version: nil, status: :failed)

        expect(failed_probe).to be_valid
      end
    end
  end

  describe '#completed?' do
    it 'is false while the probe is still running' do
      expect(probe.completed?).to be(false)
    end

    it 'is true once a result was recorded' do
      probe.update!(status: :succeeded, completed_at: Time.current, response_status: 204)

      expect(probe.completed?).to be(true)
    end
  end
end
