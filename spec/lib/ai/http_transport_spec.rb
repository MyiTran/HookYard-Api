require 'rails_helper'

describe Ai::HttpTransport do
  let(:transport) { described_class.new }
  let(:url) { 'https://generativelanguage.googleapis.com/v1beta/models/test-model:generateContent' }

  def request(**overrides)
    transport.post_json(
      url: url,
      headers: { 'x-goog-api-key' => 'test-api-key' },
      body: '{"probe":true}',
      open_timeout: 4,
      read_timeout: 4,
      **overrides
    )
  end

  def stub_http(response)
    http = double('http')
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:request).and_yield(response)
    allow(Net::HTTP).to receive(:new).and_return(http)

    http
  end

  def stub_response(chunks, code: '200')
    response = double('response', code: code)
    allow(response).to receive(:read_body) { |&block| chunks.each(&block) }

    response
  end

  it 'returns the provider status and body over https' do
    http = stub_http(stub_response(['{"ok":true}']))

    result = request

    expect(result).to have_attributes(status: 200, body: '{"ok":true}')
    expect(http).to have_received(:use_ssl=).with(true)
  end

  it 'sends the api key header and the json body to the provider' do
    response = stub_response(['{}'])
    http = double('http')
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(Net::HTTP).to receive(:new).and_return(http)
    captured = nil
    allow(http).to receive(:request) do |sent, &block|
      captured = sent
      block.call(response)
    end

    request

    expect(captured).to be_a(Net::HTTP::Post)
    expect(captured['x-goog-api-key']).to eq('test-api-key')
    expect(captured['content-type']).to eq('application/json')
    expect(captured.body).to eq('{"probe":true}')
  end

  it 'keeps non success provider statuses readable instead of raising' do
    stub_http(stub_response(['upstream unavailable'], code: '503'))

    expect(request).to have_attributes(status: 503, body: 'upstream unavailable')
  end

  it 'refuses a provider url that is not https' do
    allow(Net::HTTP).to receive(:new)

    expect { request(url: url.sub('https://', 'http://')) }.to raise_error(ArgumentError)
    expect(Net::HTTP).not_to have_received(:new)
  end

  it 'stops reading as soon as the provider body exceeds the read limit' do
    consumed = []
    response = double('response', code: '200')
    allow(response).to receive(:read_body) do |&block|
      [20_000, 20_000, 10].each do |size|
        consumed << size
        block.call('a' * size)
      end
    end
    stub_http(response)

    expect { request }.to raise_error(described_class::ResponseTooLargeError)
    expect(consumed).to eq([20_000, 20_000])
  end

  it 'accepts a provider body exactly at the read limit' do
    stub_http(stub_response(['a' * described_class::MAX_RESPONSE_BYTES]))

    expect(request.body.bytesize).to eq(described_class::MAX_RESPONSE_BYTES)
  end

  it 'logs nothing when the read limit is exceeded' do
    stub_http(stub_response(['a' * described_class::MAX_RESPONSE_BYTES, 'b']))
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:warn)

    expect { request }.to raise_error(described_class::ResponseTooLargeError)
    expect(Rails.logger).not_to have_received(:error)
    expect(Rails.logger).not_to have_received(:warn)
  end
end
