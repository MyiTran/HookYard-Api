require 'rails_helper'

describe Webhooks::DestinationResolver do
  let(:resolver) { described_class.new(timeout: 1) }
  let(:uri) { URI.parse('https://hooks.example.test/webhooks') }

  def stub_addresses(addresses)
    allow(Resolv).to receive(:getaddresses).with('hooks.example.test').and_return(addresses)
  end

  describe '#resolve' do
    context 'when the host resolves only to public addresses' do
      it 'pins the first resolved address' do
        stub_addresses(%w[93.184.216.34 203.0.114.9])

        expect(resolver.resolve(uri)).to eq('93.184.216.34')
      end
    end

    context 'when the host is not a public hostname' do
      it 'rejects it without resolving' do
        expect(Resolv).not_to receive(:getaddresses)

        expect { resolver.resolve(URI.parse('https://receiver.local/hooks')) }
          .to raise_error(described_class::NotPubliclyRoutable, described_class::NOT_ROUTABLE_MESSAGE)
      end
    end

    context 'when the host resolves to a private address' do
      it 'rejects the destination instead of retrying' do
        stub_addresses(%w[93.184.216.34 10.0.0.7])

        expect { resolver.resolve(uri) }
          .to raise_error(described_class::NotPubliclyRoutable, described_class::NOT_ROUTABLE_MESSAGE)
      end
    end

    context 'when the host resolves to a reserved address only' do
      it 'rejects the destination' do
        stub_addresses(%w[127.0.0.1])

        expect { resolver.resolve(uri) }.to raise_error(described_class::NotPubliclyRoutable)
      end
    end

    context 'when the resolver times out' do
      it 'raises a transient resolution failure' do
        allow(Resolv).to receive(:getaddresses) { raise Timeout::Error }

        expect { resolver.resolve(uri) }
          .to raise_error(described_class::ResolutionFailed, described_class::RESOLUTION_FAILED_MESSAGE)
      end
    end

    context 'when the resolver fails' do
      it 'raises a transient resolution failure' do
        allow(Resolv).to receive(:getaddresses) { raise Resolv::ResolvError }

        expect { resolver.resolve(uri) }.to raise_error(described_class::ResolutionFailed)
      end
    end

    context 'when the host does not resolve to any address' do
      it 'raises a transient resolution failure instead of a policy rejection' do
        stub_addresses([])

        expect { resolver.resolve(uri) }.to raise_error(described_class::ResolutionFailed)
      end
    end
  end
end
