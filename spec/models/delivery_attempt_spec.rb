require 'rails_helper'

describe DeliveryAttempt, type: :model do
  describe '#succeeded?' do
    it 'is true for a 2xx response' do
      expect(build(:delivery_attempt, response_status: 204)).to be_succeeded
    end

    it 'is false for a non-2xx response' do
      expect(build(:delivery_attempt, response_status: 500)).not_to be_succeeded
    end

    it 'is false when the attempt has no response' do
      expect(build(:delivery_attempt)).not_to be_succeeded
    end
  end

  describe '#transport_failed?' do
    it 'is true only when a transport error was recorded' do
      expect(build(:delivery_attempt, error_type: 'Errno::ECONNREFUSED')).to be_transport_failed
      expect(build(:delivery_attempt, response_status: 500)).not_to be_transport_failed
    end
  end

  describe '#status' do
    context 'when the attempt has a 2xx response' do
      it 'is succeeded' do
        expect(build(:delivery_attempt, response_status: 200).status).to eq('succeeded')
      end
    end

    context 'when the attempt has an error response' do
      it 'is failed' do
        expect(build(:delivery_attempt, response_status: 503).status).to eq('failed')
      end
    end

    context 'when the attempt recorded a transport error' do
      it 'is failed' do
        expect(build(:delivery_attempt, error_type: 'Net::OpenTimeout').status).to eq('failed')
      end
    end

    context 'when the attempt has no response yet' do
      it 'is in progress' do
        expect(build(:delivery_attempt).status).to eq('in_progress')
      end
    end
  end

  describe '.truncate_response_body' do
    context 'when the body is longer than the cap' do
      it 'keeps only the first 4096 bytes' do
        truncated = described_class.truncate_response_body('a' * 5000)

        expect(truncated.bytesize).to eq(described_class::RESPONSE_BODY_MAX_BYTES)
      end
    end

    context 'when the body contains multibyte characters across the cap' do
      it 'returns valid UTF-8' do
        truncated = described_class.truncate_response_body("#{'é' * 3000}")

        expect(truncated.bytesize).to be <= described_class::RESPONSE_BODY_MAX_BYTES
        expect(truncated).to be_valid_encoding
      end
    end

    context 'when the body is shorter than the cap' do
      it 'keeps the body untouched' do
        expect(described_class.truncate_response_body('ok')).to eq('ok')
      end
    end
  end

  describe '.filter_headers' do
    it 'drops sensitive headers' do
      headers = {
        'content-type' => ['application/json'],
        'set-cookie' => ['session=secret'],
        'authorization' => ['Bearer secret']
      }

      expect(described_class.filter_headers(headers)).to eq('content-type' => ['application/json'])
    end
  end

  describe 'evidence immutability' do
    it 'rejects changes to the recorded request once the attempt is stored' do
      attempt = create(:delivery_attempt)

      expect { attempt.update!(request_body: '{"tampered":true}') }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'still allows recording the response' do
      attempt = create(:delivery_attempt)

      expect { attempt.update!(response_status: 200) }.not_to raise_error
    end
  end
end
