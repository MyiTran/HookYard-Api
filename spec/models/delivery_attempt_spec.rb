require 'rails_helper'

describe DeliveryAttempt, type: :model do
  let(:attempt) { create(:delivery_attempt) }

  describe '#completed?' do
    it 'is false while the attempt has no response or error' do
      expect(attempt.completed?).to be(false)
    end

    it 'is true once a response was recorded' do
      attempt.update!(response_status: 500)

      expect(attempt.completed?).to be(true)
    end

    it 'is true once a transport error was recorded' do
      attempt.update!(error_type: 'Net::ReadTimeout', error_message: 'execution expired')

      expect(attempt.completed?).to be(true)
    end
  end

  describe 'evidence immutability' do
    it 'does not allow the outbound request to be rewritten' do
      attempt.request_url = 'https://attacker.example/hooks'

      expect(attempt).not_to be_valid
      expect(attempt.errors[:base]).to be_present
    end
  end

  describe '#status' do
    it 'reports in progress until the attempt completes' do
      expect(attempt.status).to eq('in_progress')
    end
  end
end
