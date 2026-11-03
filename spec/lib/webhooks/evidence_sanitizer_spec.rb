require 'rails_helper'

describe Webhooks::EvidenceSanitizer do
  describe '.sanitize_headers' do
    it 'drops credential headers and internal timing headers' do
      headers = {
        'Authorization' => 'Bearer secret',
        'cookie' => 'session=1',
        'set-cookie' => ['session=1'],
        'webhook-signature' => 'v1,abc',
        'x-api-key' => 'key',
        'Server-Timing' => 'sql;dur=12',
        'content-type' => 'application/json',
        'x-trace' => 'trace-1'
      }

      expect(described_class.sanitize_headers(headers)).to eq(
        'content-type' => 'application/json',
        'x-trace' => 'trace-1'
      )
    end

    it 'keeps missing headers missing' do
      expect(described_class.sanitize_headers(nil)).to be_nil
    end
  end

  describe '.sanitize_url' do
    it 'redacts sensitive query parameter values and keeps the safe ones' do
      url = 'https://example.test/hooks?token=abc&page=2&api_key=k&signature=s'

      expect(described_class.sanitize_url(url)).to eq(
        'https://example.test/hooks?token=[REDACTED]&page=2&api_key=[REDACTED]&signature=[REDACTED]'
      )
    end

    it 'keeps legitimate endpoint parameters untouched' do
      url = 'https://example.test/hooks/orders?tenant=acme&page=3#section'

      expect(described_class.sanitize_url(url)).to eq(url)
    end

    it 'returns urls without a query unchanged' do
      url = 'https://example.test/hooks'

      expect(described_class.sanitize_url(url)).to eq(url)
    end
  end
end
