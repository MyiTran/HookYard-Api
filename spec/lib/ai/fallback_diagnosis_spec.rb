require 'rails_helper'

describe Ai::FallbackDiagnosis do
  def attempt_for(response_status: nil, error_type: nil)
    build_stubbed(:delivery_attempt, response_status: response_status, error_type: error_type)
  end

  describe '.for' do
    it 'marks a rejected credential as auth_expired' do
      result = described_class.for(attempt_for(response_status: 401))

      expect(result).to have_attributes(
        label: Ai::Diagnosis::AUTH_EXPIRED,
        suggested_action: 'Check and refresh the endpoint authentication credentials, then retry delivery.',
        source: Ai::Diagnosis::SOURCE_FALLBACK,
        model: nil
      )
    end

    it 'marks a forbidden request as auth_expired' do
      expect(described_class.for(attempt_for(response_status: 403)).label).to eq(Ai::Diagnosis::AUTH_EXPIRED)
    end

    it 'marks a transport timeout as handler_timeout' do
      result = described_class.for(attempt_for(error_type: Net::ReadTimeout.name))

      expect(result).to have_attributes(
        label: Ai::Diagnosis::HANDLER_TIMEOUT,
        suggested_action: 'Increase the receiver response time or investigate why the handler exceeds the delivery timeout.'
      )
    end

    it 'marks a removed receiver as endpoint_gone' do
      result = described_class.for(attempt_for(response_status: 410))

      expect(result).to have_attributes(
        label: Ai::Diagnosis::ENDPOINT_GONE,
        suggested_action: 'Update the endpoint URL to an active receiver, then retry delivery.'
      )
    end

    it 'falls back to unknown for any other failure' do
      result = described_class.for(attempt_for(response_status: 500))

      expect(result).to have_attributes(
        label: Ai::Diagnosis::UNKNOWN,
        suggested_action: 'Review the latest delivery attempt and receiver logs, then correct the endpoint before retrying.'
      )
    end

    it 'returns an allowed label without any attempt history' do
      result = described_class.for(nil)

      expect(result.label).to eq(Ai::Diagnosis::UNKNOWN)
      expect(Ai::Diagnosis::LABELS).to include(result.label)
      expect(result.suggested_action).to be_present
    end

    it 'treats a resolved HTTP error as a receiver failure, not a transport timeout' do
      attempt = attempt_for(response_status: 504, error_type: nil)

      expect(described_class.for(attempt).label).to eq(Ai::Diagnosis::UNKNOWN)
    end
  end
end
