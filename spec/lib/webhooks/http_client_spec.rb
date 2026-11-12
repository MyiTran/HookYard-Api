require 'rails_helper'

describe Webhooks::HttpClient do
  let(:client) { described_class.new }
  let(:headers) { { 'content-type' => 'application/json' } }
  let(:body) { '{"type":"order.created"}' }
  let(:timeout) { 1 }

  def stub_http_response(chunks: [], status: 200, headers: { 'content-type' => ['application/json'] }, read_chunks: [])
    response = instance_double(Net::HTTPResponse, code: status.to_s, to_hash: headers)
    allow(response).to receive(:read_body) do |&block|
      chunks.each do |chunk|
        read_chunks << chunk
        block.call(chunk)
      end
    end

    http = instance_double(Net::HTTP)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:ipaddr=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request) { |_request, &block| block.call(response) }
    allow(Net::HTTP).to receive(:new).and_return(http)

    http
  end

  def post(url: 'https://hooks.example.com/hooks', body_limit: nil)
    options = { url: url, headers: headers, body: body, timeout: timeout }
    options[:body_limit] = body_limit unless body_limit.nil?
    client.post(**options)
  end

  describe '#post' do
    context 'when the hostname resolves to a private address' do
      it 'rejects the destination without opening a connection' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com').and_return(['10.0.0.7'])
        expect(Net::HTTP).not_to receive(:new)

        result = post

        expect(result).to be_error
        expect(result.error_type).to eq('Webhooks::DestinationResolver::NotPubliclyRoutable')
      end
    end

    context 'when the dns lookup fails' do
      it 'reports a transient resolution failure without opening a connection' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com').and_raise(Resolv::ResolvError)
        expect(Net::HTTP).not_to receive(:new)

        result = post

        expect(result).to be_error
        expect(result.error_type).to eq('Webhooks::DestinationResolver::ResolutionFailed')
      end
    end

    context 'when the hostname resolves to both public and private addresses' do
      it 'rejects the destination before the connection is attempted' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com')
                                              .and_return(['93.184.216.34', '127.0.0.1'])
        expect(Net::HTTP).not_to receive(:new)

        expect(post).to be_error
      end
    end

    context 'when the url uses an internal ip literal' do
      it 'rejects the private ip literal without a connection' do
        expect(Resolv).not_to receive(:getaddresses)
        expect(Net::HTTP).not_to receive(:new)

        expect(post(url: 'http://192.168.1.10/hooks')).to be_error
        expect(post(url: 'http://[::ffff:127.0.0.1]/hooks')).to be_error
      end
    end

    context 'when the destination is publicly routable' do
      it 'connects to the validated address while keeping the original hostname' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com')
                                              .and_return(['93.184.216.34', '2606:4700:4700::1111'])
        http = stub_http_response(chunks: ['{"ok":true}'])
        expect(Net::HTTP).to receive(:new).with('hooks.example.com', 443).and_return(http)
        expect(http).to receive(:ipaddr=).with('93.184.216.34')

        result = post

        expect(result).not_to be_error
        expect(result.status).to eq(200)
        expect(result.body).to eq('{"ok":true}')
      end
    end

    context 'when the response body is larger than the limit' do
      it 'stops reading once the limit is exceeded and keeps the capped body' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com').and_return(['93.184.216.34'])
        read_chunks = []
        stub_http_response(chunks: ['a' * 3000, 'b' * 3000, 'c' * 3000], read_chunks: read_chunks)

        result = post(body_limit: DeliveryAttempt::RESPONSE_BODY_MAX_BYTES)

        expect(read_chunks.size).to eq(2)
        expect(result.body.bytesize).to eq(DeliveryAttempt::RESPONSE_BODY_MAX_BYTES)
        expect(result.body).to eq(('a' * 3000) + ('b' * 1096))
        expect(result.status).to eq(200)
      end
    end

    context 'when the receiver answers with a redirect' do
      it 'records the redirect status without following it' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com').and_return(['93.184.216.34'])
        http = stub_http_response(status: 302, headers: { 'location' => ['https://elsewhere.example.com'] })

        result = post

        expect(result.status).to eq(302)
        expect(http).to have_received(:request).once
      end
    end

    context 'when the connection fails' do
      it 'returns a transport error result' do
        allow(Resolv).to receive(:getaddresses).with('hooks.example.com').and_return(['93.184.216.34'])
        http = stub_http_response
        allow(http).to receive(:start).and_raise(Net::OpenTimeout)

        result = post

        expect(result).to be_error
        expect(result.error_type).to eq('Net::OpenTimeout')
        expect(result.status).to be_nil
      end
    end
  end
end
