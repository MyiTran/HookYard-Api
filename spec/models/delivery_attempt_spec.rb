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

  describe '#completed?' do
    it 'is false while the attempt has no response or error' do
      expect(build(:delivery_attempt).completed?).to be(false)
    end

    it 'is true once a response was recorded' do
      expect(build(:delivery_attempt, response_status: 500).completed?).to be(true)
    end

    it 'is true once a transport error was recorded' do
      expect(build(:delivery_attempt, error_type: 'Net::ReadTimeout').completed?).to be(true)
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

  describe 'persisting externally received response text' do
    let(:invalid_utf8_bytes) { [0xC3, 0x28, 0xA0].pack('C*') }

    context 'when the receiver body contains invalid UTF-8 bytes' do
      it 'stores the body as valid UTF-8 text' do
        attempt = create(:delivery_attempt, response_body: described_class.truncate_response_body(invalid_utf8_bytes))

        stored_body = attempt.reload.response_body

        expect(stored_body).to be_valid_encoding
        expect(stored_body).to eq("\uFFFD(\uFFFD")
      end
    end

    context 'when the receiver body exceeds the byte limit' do
      it 'limits the body to RESPONSE_BODY_MAX_BYTES before normalizing' do
        body = ('a' * described_class::RESPONSE_BODY_MAX_BYTES) + invalid_utf8_bytes

        attempt = create(:delivery_attempt, response_body: described_class.truncate_response_body(body))

        expect(attempt.reload.response_body).to eq('a' * described_class::RESPONSE_BODY_MAX_BYTES)
        expect(attempt.reload.response_body.bytesize).to eq(described_class::RESPONSE_BODY_MAX_BYTES)
      end

      it 'replaces a multibyte character cut by the byte limit' do
        truncated_character = [0xE2, 0x82].pack('C*')
        body = ('a' * (described_class::RESPONSE_BODY_MAX_BYTES - 1)) + truncated_character

        attempt = create(:delivery_attempt, response_body: described_class.truncate_response_body(body))
        stored_body = attempt.reload.response_body

        expect(stored_body).to be_valid_encoding
        expect(stored_body).to eq("#{'a' * (described_class::RESPONSE_BODY_MAX_BYTES - 1)}\uFFFD")
      end
    end

    context 'when the transport error message contains invalid bytes' do
      it 'stores the message as valid UTF-8 text' do
        attempt = create(
          :delivery_attempt,
          error_type: 'Errno::ECONNRESET',
          error_message: described_class.truncate_error_message(invalid_utf8_bytes)
        )

        stored_message = attempt.reload.error_message

        expect(stored_message).to be_valid_encoding
        expect(stored_message).to eq("\uFFFD(\uFFFD")
      end

      it 'limits the message to ERROR_MESSAGE_MAX_BYTES before normalizing' do
        error_text = invalid_utf8_bytes + ('z' * described_class::ERROR_MESSAGE_MAX_BYTES)

        attempt = create(
          :delivery_attempt,
          error_type: 'Errno::ECONNRESET',
          error_message: described_class.truncate_error_message(error_text)
        )

        stored_message = attempt.reload.error_message

        expect(stored_message).to be_valid_encoding
        expect(stored_message.count('z')).to eq(described_class::ERROR_MESSAGE_MAX_BYTES - invalid_utf8_bytes.bytesize)
      end
    end

    context 'when the receiver response headers contain invalid bytes' do
      it 'stores the header values as valid UTF-8' do
        headers = described_class.filter_headers('x-upstream-error' => [invalid_utf8_bytes])

        attempt = create(:delivery_attempt, response_status: 502, response_headers: headers)
        stored_headers = attempt.reload.response_headers

        expect(stored_headers['x-upstream-error']).to eq(["\uFFFD(\uFFFD"])
        expect(stored_headers['x-upstream-error'].first).to be_valid_encoding
      end

      it 'keeps multi-value headers as arrays' do
        headers = described_class.filter_headers('x-request-id' => %w[first second])

        attempt = create(:delivery_attempt, response_status: 200, response_headers: headers)

        expect(attempt.reload.response_headers['x-request-id']).to eq(%w[first second])
      end

      it 'excludes every sensitive header' do
        headers = described_class.filter_headers(
          'set-cookie' => ['session=secret'],
          'cookie' => ['session=secret'],
          'authorization' => ['Bearer secret'],
          'proxy-authenticate' => ['Basic realm=secret'],
          'www-authenticate' => ['Basic realm=secret'],
          'content-type' => ['application/json']
        )

        attempt = create(:delivery_attempt, response_status: 200, response_headers: headers)

        expect(attempt.reload.response_headers).to eq('content-type' => ['application/json'])
      end
    end
  end
end
