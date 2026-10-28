require 'rails_helper'

describe Webhooks::FailureCategory do
  describe '.for' do
    it 'classifies a rejected destination as its own category' do
      expect(described_class.for(error_type: 'Webhooks::DestinationResolver::NotPubliclyRoutable'))
        .to eq(described_class::DESTINATION_REJECTED)
    end

    it 'classifies timeouts from the transport layer' do
      %w[Timeout::Error Net::OpenTimeout Net::ReadTimeout Net::WriteTimeout Errno::ETIMEDOUT].each do |error_type|
        expect(described_class.for(error_type: error_type)).to eq(described_class::TIMEOUT)
      end
    end

    it 'classifies other transport failures as network errors' do
      %w[Errno::ECONNREFUSED SocketError OpenSSL::SSL::SSLError
         Webhooks::DestinationResolver::ResolutionFailed].each do |error_type|
        expect(described_class.for(error_type: error_type)).to eq(described_class::NETWORK)
      end
    end

    it 'classifies a response failure as an http error' do
      expect(described_class.for(response_status: 500)).to eq(described_class::HTTP_ERROR)
      expect(described_class.for(response_status: 404)).to eq(described_class::HTTP_ERROR)
    end

    it 'classifies an aborted attempt as interrupted' do
      expect(described_class.for(error_type: DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE))
        .to eq(described_class::INTERRUPTED)
    end

    it 'has no category for a successful or unfinished attempt' do
      expect(described_class.for(response_status: nil, error_type: nil)).to be_nil
    end
  end

  describe 'categories' do
    it 'are stable client-facing strings' do
      expect(described_class::DESTINATION_REJECTED).to eq('destination_rejected')
      expect(described_class::TIMEOUT).to eq('timeout')
      expect(described_class::NETWORK).to eq('network')
      expect(described_class::HTTP_ERROR).to eq('http_error')
      expect(described_class::INTERRUPTED).to eq('interrupted')
    end

    it 'cover the lease expiry error type used by the delivery attempts' do
      expect(described_class::INTERRUPTED_ERROR_TYPES).to include(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
    end
  end
end
