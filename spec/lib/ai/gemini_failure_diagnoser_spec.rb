require 'rails_helper'

describe Ai::GeminiFailureDiagnoser do
  let(:transport) { double('transport') }
  let(:api_key) { 'test-api-key' }
  let(:model) { 'gemini-test-model' }
  let(:diagnoser) { described_class.new(api_key: api_key, model: model, timeout_ms: 4000, transport: transport) }
  let(:attempt) do
    build_stubbed(
      :delivery_attempt,
      response_status: 500,
      response_headers: { 'content-type' => 'text/html', 'authorization' => 'Bearer receiver-secret' },
      response_body: Oj.dump({ 'error' => 'boom', 'token' => 'receiver-token' }, mode: :compat),
      duration_ms: 900
    )
  end

  def provider_response(answer)
    body = Oj.dump({ candidates: [{ content: { parts: [{ text: answer }] } }] }, mode: :compat)

    Ai::HttpTransport::Result.new(status: 200, body: body)
  end

  def valid_answer(label: Ai::Diagnosis::HANDLER_TIMEOUT, action: 'Raise the receiver timeout and retry the delivery.')
    provider_response(Oj.dump({ label: label, suggested_action: action }, mode: :compat))
  end

  def captured_body
    captured = nil
    allow(transport).to receive(:post_json) do |**arguments|
      captured = arguments
    end
    diagnoser.call([attempt])
    Oj.load(captured[:body])
  end

  describe '#call' do
    it 'returns an ai result when the provider answer passes validation' do
      allow(transport).to receive(:post_json).and_return(valid_answer)

      result = diagnoser.call([attempt])

      expect(result).to have_attributes(
        label: Ai::Diagnosis::HANDLER_TIMEOUT,
        suggested_action: 'Raise the receiver timeout and retry the delivery.',
        source: Ai::Diagnosis::SOURCE_AI,
        model: model
      )
      expect(result).to be_ai
    end

    it 'asks for the label enum through a structured response schema' do
      body = captured_body
      schema = body.dig('generationConfig', 'responseSchema')

      expect(body.dig('generationConfig', 'responseMimeType')).to eq('application/json')
      expect(schema['properties']['label']['enum']).to eq(Ai::Diagnosis::LABELS)
      expect(schema['required']).to contain_exactly('label', 'suggested_action')
    end

    it 'posts to the https provider endpoint with the api key in a header only' do
      captured = nil
      allow(transport).to receive(:post_json) do |**arguments|
      captured = arguments
    end
      diagnoser.call([attempt])

      expect(captured[:url]).to eq("https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent")
      expect(captured[:headers]).to eq('x-goog-api-key' => api_key)
      expect(captured[:body]).not_to include(api_key)
      expect(captured[:url]).not_to include(api_key)
    end

    it 'bounds both connection and read timeouts from the configured milliseconds' do
      captured = nil
      allow(transport).to receive(:post_json) do |**arguments|
      captured = arguments
    end
      diagnoser.call([attempt])

      expect(captured).to include(open_timeout: 4.0, read_timeout: 4.0)
    end

    it 'sends sanitized evidence only, never request evidence or receiver secrets' do
      body = Oj.dump(captured_body, mode: :compat)

      expect(body).to include(Webhooks::EvidenceSanitizer::REDACTED_VALUE)
      expect(body).not_to include('receiver-secret', 'receiver-token', 'request_body', 'request_headers')
    end

    it 'bounds the prompt size' do
      allow(transport).to receive(:post_json).and_return(valid_answer)
      attempts = Array.new(20) { build_stubbed(:delivery_attempt, response_status: 500, response_body: 'b' * 4000) }

      captured = nil
      allow(transport).to receive(:post_json) do |**arguments|
      captured = arguments
    end
      diagnoser.call(attempts)

      prompt = Oj.load(captured[:body]).dig('contents', 0, 'parts', 0, 'text')
      expect(prompt.bytesize).to be <= described_class::PROMPT_MAX_BYTES
    end

    it 'returns nil without calling the provider when the api key is missing' do
      allow(transport).to receive(:post_json)

      expect(described_class.new(api_key: nil, transport: transport).call([attempt])).to be_nil
      expect(transport).not_to have_received(:post_json)
    end

    it 'returns nil for a provider error status' do
      allow(transport).to receive(:post_json)
        .and_return(Ai::HttpTransport::Result.new(status: 503, body: 'upstream unavailable'))

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'returns nil for a malformed provider envelope' do
      allow(transport).to receive(:post_json).and_return(Ai::HttpTransport::Result.new(status: 200, body: 'not-json'))

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'returns nil when the answer is not a JSON object' do
      allow(transport).to receive(:post_json).and_return(provider_response('I think it is a timeout'))

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'returns nil when the answer uses a label outside the allowed enum' do
      allow(transport).to receive(:post_json).and_return(valid_answer(label: 'cosmic_rays'))

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'returns nil when the suggested action is blank' do
      allow(transport).to receive(:post_json).and_return(valid_answer(action: '   '))

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'returns nil when the suggested action exceeds the bound' do
      allow(transport).to receive(:post_json)
        .and_return(valid_answer(action: 'a' * (Ai::Diagnosis::ACTION_MAX_LENGTH + 1)))

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'ignores extra answer keys' do
      answer = Oj.dump({ label: Ai::Diagnosis::RATE_LIMITED, suggested_action: 'Slow down the retries.',
                         confidence: 0.9 }, mode: :compat)
      allow(transport).to receive(:post_json).and_return(provider_response(answer))

      expect(diagnoser.call([attempt]).label).to eq(Ai::Diagnosis::RATE_LIMITED)
    end

    it 'returns nil on a provider timeout' do
      allow(transport).to receive(:post_json).and_raise(Net::OpenTimeout)

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'returns nil on a network failure' do
      allow(transport).to receive(:post_json).and_raise(Errno::ECONNREFUSED)

      expect(diagnoser.call([attempt])).to be_nil
    end

    it 'never logs the provider payload or error details' do
      allow(transport).to receive(:post_json).and_raise(Errno::ECONNREFUSED)
      allow(Rails.logger).to receive(:info)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:error)

      diagnoser.call([attempt])

      expect(Rails.logger).not_to have_received(:info)
      expect(Rails.logger).not_to have_received(:warn)
      expect(Rails.logger).not_to have_received(:error)
    end
  end
end
