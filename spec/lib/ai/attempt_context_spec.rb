require 'rails_helper'

describe Ai::AttemptContext do
  def attempt_for(**attributes)
    build_stubbed(:delivery_attempt, **attributes)
  end

  describe '.for' do
    it 'exposes only the minimal diagnostic evidence' do
      context = described_class.for(attempt_for(response_status: 500, duration_ms: 120))

      expect(context.keys).to contain_exactly(
        :response_status, :response_headers, :response_body_excerpt, :duration_ms, :failure_category, :occurred_at
      )
    end

    it 'never includes request evidence' do
      context = described_class.for(attempt_for(response_status: 500))
      serialized = Oj.dump(context, mode: :compat)

      expect(serialized).not_to include('request_body')
      expect(serialized).not_to include('request_headers')
      expect(serialized).not_to include('request_url')
    end

    it 'drops credential headers' do
      context = described_class.for(
        attempt_for(response_headers: { 'authorization' => 'Bearer secret-token', 'set-cookie' => 'session=1',
                                       'content-type' => 'application/json' })
      )

      expect(context[:response_headers]).to eq('content-type' => 'application/json')
    end

    it 'bounds the header count and each header value' do
      headers = Array.new(described_class::HEADER_LIMIT + 5) { |index| ["x-header-#{index}", 'v' * 500] }.to_h

      context = described_class.for(attempt_for(response_headers: headers))

      expect(context[:response_headers].size).to eq(described_class::HEADER_LIMIT)
      expect(context[:response_headers].values.map(&:bytesize).max)
        .to be <= described_class::HEADER_VALUE_MAX_BYTES
    end

    it 'redacts sensitive JSON body keys' do
      context = described_class.for(
        attempt_for(response_body: Oj.dump({ 'error' => 'nope', 'token' => 'live-token' }, mode: :compat))
      )

      expect(context[:response_body_excerpt]).to include(Webhooks::EvidenceSanitizer::REDACTED_VALUE)
      expect(context[:response_body_excerpt]).not_to include('live-token')
    end

    it 'truncates the body excerpt' do
      context = described_class.for(attempt_for(response_body: 'a' * 4000))

      expect(context[:response_body_excerpt].bytesize).to be <= described_class::BODY_EXCERPT_MAX_BYTES
    end

    it 'returns no excerpt for a purged body' do
      expect(described_class.for(attempt_for(response_body: nil))[:response_body_excerpt]).to be_nil
    end

    it 'exposes the normalized failure category instead of the error class' do
      context = described_class.for(attempt_for(response_status: nil, error_type: Net::ReadTimeout.name))

      expect(context[:failure_category]).to eq(Webhooks::FailureCategory::TIMEOUT)
    end

    it 'reports the attempt time in UTC' do
      context = described_class.for(attempt_for(response_status: 500, created_at: Time.utc(2026, 5, 1, 3, 0, 0)))

      expect(context[:occurred_at]).to eq('2026-05-01T03:00:00Z')
    end
  end

  describe '.attempt_limit' do
    it 'uses the configured limit' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('AI_DIAGNOSIS_ATTEMPT_LIMIT', nil).and_return('3')

      expect(described_class.attempt_limit).to eq(3)
    end

    it 'falls back to the default when the value is not usable' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('AI_DIAGNOSIS_ATTEMPT_LIMIT', nil).and_return('not-a-number')

      expect(described_class.attempt_limit).to eq(described_class::ATTEMPT_LIMIT_DEFAULT)
    end

    it 'caps the configured limit' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('AI_DIAGNOSIS_ATTEMPT_LIMIT', nil).and_return('5000')

      expect(described_class.attempt_limit).to eq(described_class::ATTEMPT_LIMIT_DEFAULT)
    end
  end
end
