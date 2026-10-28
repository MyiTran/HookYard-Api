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

    context 'when the host is a private or reserved ip literal' do
      %w[
        http://10.0.0.7/hooks
        http://127.0.0.1/hooks
        http://169.254.169.254/hooks
        http://192.168.1.10/hooks
        http://[::1]/hooks
        http://[::ffff:127.0.0.1]/hooks
        http://[fd00::1]/hooks
        http://[64:ff9b::10.0.0.7]/hooks
      ].each do |url|
        it "rejects #{url} as not publicly routable" do
          expect(Resolv).not_to receive(:getaddresses)

          expect { described_class.new.resolve(URI.parse(url)) }
            .to raise_error(described_class::NotPubliclyRoutable)
        end
      end
    end

    context 'when the resolved address is a dns-rebinding private address' do
      it 'rejects the destination instead of pinning it' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com')
                                              .and_return(['::ffff:169.254.169.254'])

        expect { described_class.new.resolve(URI.parse('https://hooks.example.com/hooks')) }
          .to raise_error(described_class::NotPubliclyRoutable)
      end
    end

    context 'when the dns lookup times out' do
      it 'reports a transient resolution failure' do
        allow(Resolv).to receive(:getaddresses).with('slow.example.com').and_raise(Timeout::Error)

        expect { described_class.new.resolve(URI.parse('https://slow.example.com/hooks')) }
          .to raise_error(described_class::ResolutionFailed)
      end

      it 'enforces its own lookup timeout' do
        allow(Resolv).to receive(:getaddresses).with('slow.example.com') do
          sleep 0.2
          ['93.184.216.34']
        end

        expect { described_class.new(timeout: 0.01).resolve(URI.parse('https://slow.example.com/hooks')) }
          .to raise_error(described_class::ResolutionFailed)
      end
    end

    context 'when the dns resolver reports an error' do
      it 'reports a transient resolution failure' do
        allow(Resolv).to receive(:getaddresses).with('broken.example.com')
                                              .and_raise(Resolv::ResolvError)

        expect { described_class.new.resolve(URI.parse('https://broken.example.com/hooks')) }
          .to raise_error(described_class::ResolutionFailed)
      end

      it 'reports a transient resolution failure when the system resolver fails' do
        allow(Resolv).to receive(:getaddresses).with('broken.example.com').and_raise(SocketError)

        expect { described_class.new.resolve(URI.parse('https://broken.example.com/hooks')) }
          .to raise_error(described_class::ResolutionFailed)
      end
    end

    context 'when the dns lookup returns no usable address' do
      it 'reports a transient resolution failure' do
        allow(Resolv).to receive(:getaddresses).with('unresolvable.example.com').and_return([])

        expect { described_class.new.resolve(URI.parse('https://unresolvable.example.com/hooks')) }
          .to raise_error(described_class::ResolutionFailed)
      end
    end
  end
end
