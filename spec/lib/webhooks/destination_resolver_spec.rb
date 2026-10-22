require 'rails_helper'

describe Webhooks::DestinationResolver do
  describe '#resolve' do
    context 'when the hostname resolves to public addresses only' do
      it 'returns the first validated address' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com')
                                              .and_return(['93.184.216.34', '2606:4700:4700::1111'])

        address = described_class.new.resolve(URI.parse('https://hooks.example.com/hooks'))

        expect(address).to eq('93.184.216.34')
      end
    end

    context 'when any resolved address is not publicly routable' do
      it 'rejects the destination' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com')
                                              .and_return(['93.184.216.34', '169.254.169.254'])

        expect { described_class.new.resolve(URI.parse('https://hooks.example.com/hooks')) }
          .to raise_error(described_class::NotPubliclyRoutable)
      end
    end

    context 'when the hostname is internal' do
      it 'rejects the destination without resolving it' do
        expect(Resolv).not_to receive(:getaddresses)

        expect { described_class.new.resolve(URI.parse('http://billing.internal/hooks')) }
          .to raise_error(described_class::NotPubliclyRoutable)
      end
    end

    context 'when the host is an ambiguous numeric form' do
      it 'rejects the destination' do
        expect(Resolv).not_to receive(:getaddresses)

        expect { described_class.new.resolve(URI.parse('http://2130706433/hooks')) }
          .to raise_error(described_class::NotPubliclyRoutable)
      end
    end

    context 'when the host is a public ip literal' do
      it 'returns the literal without a dns lookup' do
        expect(Resolv).not_to receive(:getaddresses)

        address = described_class.new.resolve(URI.parse('https://[2606:4700:4700::1111]/hooks'))

        expect(address).to eq('2606:4700:4700::1111')
      end
    end

    context 'when the hostname can not be resolved' do
      it 'rejects the destination' do
        allow(Resolv).to receive(:getaddresses).with('unresolvable.example.com').and_return([])

        expect { described_class.new.resolve(URI.parse('https://unresolvable.example.com/hooks')) }
          .to raise_error(described_class::NotPubliclyRoutable)
      end
    end
  end
end
