require 'rails_helper'

describe Webhooks::DeliveryPolicy, type: :model do
  describe '.attempt_offsets' do
    it 'runs the first attempt immediately and retries on the default schedule' do
      expect(described_class.attempt_offsets).to eq(
        [
          0.seconds,
          5.seconds,
          5.minutes,
          30.minutes,
          2.hours,
          5.hours,
          10.hours,
          10.hours
        ]
      )
    end

    it 'allows eight total attempts including the first one' do
      expect(described_class::MAX_ATTEMPTS).to eq(8)
      expect(described_class.attempt_offsets.size).to eq(described_class::MAX_ATTEMPTS)
    end

    context 'when jitter sits at its bounds' do
      it 'reproduces the exact base schedule without any early retry' do
        described_class.jitter_source = -> { 0 }

        expect(described_class.attempt_offsets).to eq(
          [0.seconds, 5.seconds, 5.minutes, 30.minutes, 2.hours, 5.hours, 10.hours, 10.hours]
        )
      end
    end

    context 'when the tenant is on the free plan' do
      it 'keeps the fixed schedule even if override columns were persisted' do
        project = build(:project)
        project.delivery_retry_delays_seconds = [120, 120, 120]

        expect(described_class.attempt_offsets(project: project)).to eq(
          [0.seconds, 5.seconds, 5.minutes, 30.minutes, 2.hours, 5.hours, 10.hours, 10.hours]
        )
      end
    end
  end

  describe '.retry_delay' do
    before { described_class.jitter_source = -> { 0.5 } }

    it 'returns the jittered schedule for every retryable attempt' do
      expect(described_class.retry_delay(1)).to be_within(0.001).of(5.5.seconds)
      expect(described_class.retry_delay(2)).to be_within(0.001).of(5.minutes + 30.seconds)
      expect(described_class.retry_delay(3)).to be_within(0.001).of(33.minutes)
      expect(described_class.retry_delay(4)).to be_within(0.001).of(2.hours + 12.minutes)
      expect(described_class.retry_delay(5)).to be_within(0.001).of(5.hours + 30.minutes)
      expect(described_class.retry_delay(6)).to be_within(0.001).of(11.hours)
      expect(described_class.retry_delay(7)).to be_within(0.001).of(11.hours)
    end

    it 'never returns a delay earlier than the base schedule' do
      100.times do
        expect(described_class.retry_delay(2)).to be >= 5.minutes
      end
    end

    it 'never exceeds the bounded positive jitter window' do
      100.times do
        expect(described_class.retry_delay(2)).to be < 5.minutes * 1.2
      end
    end

    it 'returns nil once every attempt has been used' do
      expect(described_class.retry_delay(described_class::MAX_ATTEMPTS)).to be_nil
      expect(described_class.retry_delay(described_class::MAX_ATTEMPTS + 1)).to be_nil
    end

    it 'returns nil for an attempt count below one' do
      expect(described_class.retry_delay(0)).to be_nil
    end

    context 'when jitter spans its bounds' do
      it 'keeps every retry between the base delay and the twenty percent cap' do
        described_class.jitter_source = -> { 0 }
        expect((1..7).map { |attempts| described_class.retry_delay(attempts) }).to eq(
          described_class::DEFAULT_RETRY_DELAYS
        )

        described_class.jitter_source = -> { 0.999999 }
        described_class::DEFAULT_RETRY_DELAYS.each_with_index do |base, index|
          expect(described_class.retry_delay(index + 1)).to be_between(base, base * 1.2)
        end
      end
    end

    context 'when the tenant is on the free plan' do
      it 'uses the fixed default schedule' do
        project = build(:project)

        expect(described_class.retry_delays_for(project)).to eq(described_class::DEFAULT_RETRY_DELAYS)
      end
    end

    context 'when the tenant is on the pro plan' do
      it 'uses the configured retry delays' do
        project = build(:project, :pro, delivery_retry_delays_seconds: [3, 60])

        expect(described_class.retry_delays_for(project)).to eq([3.seconds, 1.minute])
        expect(described_class.retry_delay(1, project: project)).to be_within(1).of(3.seconds)
      end
    end
  end

  describe '.timeout_seconds_for' do
    it 'defaults the free plan to fifteen seconds' do
      expect(described_class::DEFAULT_HTTP_TIMEOUT_SECONDS).to eq(15)
      expect(described_class.timeout_seconds_for(build(:project))).to eq(15)
    end

    it 'returns the configured timeout for the pro plan' do
      project = build(:project, :pro, delivery_timeout_seconds: 30)

      expect(described_class.timeout_seconds_for(project)).to eq(30)
    end

    it 'falls back to the default when the pro plan has no override' do
      expect(described_class.timeout_seconds_for(build(:project, :pro))).to eq(15)
    end

    it 'ignores persisted timeout columns on the free plan' do
      project = build(:project)
      project.delivery_timeout_seconds = 30

      expect(described_class.timeout_seconds_for(project)).to eq(15)
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

    it 'retries a transient destination resolution failure' do
      expect(described_class.retryable_error?('Webhooks::DestinationResolver::ResolutionFailed')).to be(true)
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
