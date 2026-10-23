require 'rails_helper'

describe Webhooks::DeliveryPolicy, type: :model do
  describe '.retry_delay' do
    it 'returns the jittered schedule for every retryable attempt' do
      expect(described_class.retry_delay(1)).to be_between(1.minute, 1.minute * 1.2)
      expect(described_class.retry_delay(2)).to be_between(5.minutes, 5.minutes * 1.2)
      expect(described_class.retry_delay(3)).to be_between(15.minutes, 15.minutes * 1.2)
      expect(described_class.retry_delay(4)).to be_between(60.minutes, 60.minutes * 1.2)
    end

    it 'never returns a delay earlier than the base schedule' do
      100.times do
        expect(described_class.retry_delay(2)).to be >= 5.minutes
      end
    end

    it 'never exceeds the bounded jitter window' do
      100.times do
        expect(described_class.retry_delay(2)).to be < 5.minutes * 1.2
      end
    end

    it 'returns nil once every attempt has been used' do
      expect(described_class.retry_delay(described_class::MAX_ATTEMPTS)).to be_nil
      expect(described_class.retry_delay(described_class::MAX_ATTEMPTS + 1)).to be_nil
    end
  end

  describe '.capacity_retry_delay' do
    it 'returns a short positive jittered delay' do
      100.times do
        delay = described_class.capacity_retry_delay

        expect(delay).to be_between(described_class::CAPACITY_RETRY_DELAY, described_class::CAPACITY_RETRY_DELAY * 1.2)
      end
    end
  end

  describe '.retryable_status?' do
    it 'retries 408, 429 and 5xx responses' do
      expect(described_class.retryable_status?(408)).to be(true)
      expect(described_class.retryable_status?(429)).to be(true)
      expect(described_class.retryable_status?(500)).to be(true)
      expect(described_class.retryable_status?(599)).to be(true)
    end

    it 'does not retry success, redirect or other client error responses' do
      expect(described_class.retryable_status?(200)).to be(false)
      expect(described_class.retryable_status?(204)).to be(false)
      expect(described_class.retryable_status?(301)).to be(false)
      expect(described_class.retryable_status?(400)).to be(false)
      expect(described_class.retryable_status?(404)).to be(false)
      expect(described_class.retryable_status?(422)).to be(false)
    end
  end

  describe '.retryable_error?' do
    it 'retries network, transport and timeout errors' do
      %w[Net::ReadTimeout Net::OpenTimeout Net::WriteTimeout Timeout::Error SocketError
         Errno::ECONNREFUSED Errno::ECONNRESET Errno::EHOSTUNREACH IOError EOFError].each do |error_type|
        expect(described_class.retryable_error?(error_type)).to be(true)
      end
    end

    it 'does not retry security, signing or malformed destination errors' do
      %w[Webhooks::DestinationResolver::NotPubliclyRoutable URI::InvalidURIError
         ArgumentError Webhooks::Signer::InvalidSecret].each do |error_type|
        expect(described_class.retryable_error?(error_type)).to be(false)
      end
    end
  end

  describe '.retryable?' do
    it 'classifies a transport result by its error type' do
      result = Webhooks::HttpClient::Result.new(error: 'timed out', error_type: 'Net::ReadTimeout')

      expect(described_class.retryable?(result)).to be(true)
    end

    it 'classifies a response result by its status' do
      retryable = Webhooks::HttpClient::Result.new(status: 503, headers: {}, body: '')
      terminal = Webhooks::HttpClient::Result.new(status: 404, headers: {}, body: '')

      expect(described_class.retryable?(retryable)).to be(true)
      expect(described_class.retryable?(terminal)).to be(false)
    end
  end
end
