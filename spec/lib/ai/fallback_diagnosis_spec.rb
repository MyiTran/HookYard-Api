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

    it 'marks a not-found receiver as endpoint_gone' do
      expect(described_class.for(attempt_for(response_status: 404)).label).to eq(Ai::Diagnosis::ENDPOINT_GONE)
    end

    [400, 409, 415, 422].each do |status|
      it "marks a #{status} rejection as payload_rejected" do
        result = described_class.for(attempt_for(response_status: status))

        expect(result).to have_attributes(
          label: Ai::Diagnosis::PAYLOAD_REJECTED,
          suggested_action: 'Validate the webhook payload against the receiver contract, then retry delivery.',
          source: Ai::Diagnosis::SOURCE_FALLBACK,
          model: nil
        )
      end
    end

    [408, 504].each do |status|
      it "marks a #{status} response as handler_timeout" do
        expect(described_class.for(attempt_for(response_status: status)).label).to eq(Ai::Diagnosis::HANDLER_TIMEOUT)
      end
    end

    it 'marks a rate limit as rate_limited' do
      result = described_class.for(attempt_for(response_status: 429))

      expect(result).to have_attributes(
        label: Ai::Diagnosis::RATE_LIMITED,
        suggested_action: 'Reduce the delivery rate or retry after the receiver rate limit resets.'
      )
    end

    it 'maps receiver 5xx responses to unknown because no dedicated receiver-error label exists' do
      [500, 502, 503].each do |status|
        result = described_class.for(attempt_for(response_status: status))

        expect(result).to have_attributes(
          label: Ai::Diagnosis::UNKNOWN,
          suggested_action: 'Review the latest delivery attempt and receiver logs, then correct the endpoint before retrying.',
          source: Ai::Diagnosis::SOURCE_FALLBACK,
          model: nil
        )
      end
    end

    it 'marks a TLS failure as tls_failure' do
      result = described_class.for(attempt_for(error_type: OpenSSL::SSL::SSLError.name))

      expect(result).to have_attributes(
        label: Ai::Diagnosis::TLS_FAILURE,
        suggested_action: 'Check the receiver TLS certificate and supported TLS configuration, then retry delivery.'
      )
    end

    it 'falls back to unknown for non-TLS DNS and connection transport failures' do
      [SocketError.name, Errno::ECONNRESET.name, Errno::ECONNREFUSED.name].each do |error_type|
        result = described_class.for(attempt_for(error_type: error_type))

        expect(result).to have_attributes(
          label: Ai::Diagnosis::UNKNOWN,
          suggested_action: 'Review the latest delivery attempt and receiver logs, then correct the endpoint before retrying.'
        )
      end
    end

    it 'falls back to unknown for any other failure' do
      result = described_class.for(attempt_for(response_status: 302))

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

    it 'classifies the newest attempt from a collection' do
      newer = attempt_for(response_status: 400)
      older = attempt_for(response_status: 401)

      expect(described_class.for([newer, older]).label).to eq(Ai::Diagnosis::PAYLOAD_REJECTED)
    end

    it 'chooses the dominant label across all selected attempts' do
      attempts = Array.new(8) { attempt_for(response_status: 400) } +
                 Array.new(2) { attempt_for(response_status: 500) }

      result = described_class.for(attempts)

      expect(result.label).to eq(Ai::Diagnosis::PAYLOAD_REJECTED)
      expect(result.analyzed_attempt_count).to eq(10)
    end

    it 'breaks a tie using the newest attempt when the newest is payload_rejected' do
      attempts = Array.new(5) { attempt_for(response_status: 400) } +
                 Array.new(5) { attempt_for(response_status: 500) }

      result = described_class.for(attempts)

      expect(result.label).to eq(Ai::Diagnosis::PAYLOAD_REJECTED)
    end

    it 'breaks a tie using the newest attempt when the newest is unknown' do
      attempts = Array.new(5) { attempt_for(response_status: 500) } +
                 Array.new(5) { attempt_for(response_status: 400) }

      result = described_class.for(attempts)

      expect(result.label).to eq(Ai::Diagnosis::UNKNOWN)
    end
  end
end
