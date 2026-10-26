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

  describe 'external text normalization' do
    let(:binary_payload) { "binary\xFF\xFE".b }

    it 'stores a binary receiver body as valid UTF-8' do
      attempt.update!(response_status: 500, response_body: described_class.truncate_response_body(binary_payload))

      expect(attempt.reload.response_body).to be_valid_encoding
      expect(attempt.response_body.encoding).to eq(Encoding::UTF_8)
    end

    it 'stores a binary transport error message as valid UTF-8' do
      attempt.update!(error_type: 'Net::ReadTimeout', error_message: described_class.truncate_error_message(binary_payload))

      expect(attempt.reload.error_message).to be_valid_encoding
    end

    it 'drops credential headers and normalizes binary header values' do
      filtered = described_class.filter_headers(
        'set-cookie' => 'session=1',
        'authorization' => 'Bearer token',
        'x-trace' => [binary_payload],
        'content-type' => 'text/plain'
      )

      expect(filtered.keys).to contain_exactly('x-trace', 'content-type')
      expect(filtered['x-trace'].first).to be_valid_encoding
    end

    it 'bounds the stored response body to the byte limit' do
      oversized = 'a' * (described_class::RESPONSE_BODY_MAX_BYTES + 10)

      expect(described_class.truncate_response_body(oversized).bytesize)
        .to be <= described_class::RESPONSE_BODY_MAX_BYTES
    end
  end
end
