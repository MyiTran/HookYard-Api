require 'rails_helper'

describe Webhooks::DestinationPolicy do
  describe '.public_host?' do
    it 'rejects IPv4-mapped IPv6 addresses that embed a public IPv4 address' do
      expect(described_class.public_host?('[::ffff:93.184.216.34]')).to be(false)
    end

    it 'rejects IPv4-mapped IPv6 addresses that embed a loopback IPv4 address' do
      expect(described_class.public_host?('[::ffff:127.0.0.1]')).to be(false)
    end

    it 'accepts a public IPv4 address' do
      expect(described_class.public_host?('93.184.216.34')).to be(true)
    end

    it 'accepts a public IPv6 address' do
      expect(described_class.public_host?('[2606:4700:4700::1111]')).to be(true)
    end
  end
end
