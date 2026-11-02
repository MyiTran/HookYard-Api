require 'rails_helper'

describe Webhooks::DeliveryPolicy, type: :model do
  after { described_class.reset_jitter_source! }

  def with_jitter(value)
    described_class.jitter_source = -> { value }
  end

  describe 'production contract' do
    it 'allows eight total attempts' do
      expect(described_class::MAX_ATTEMPTS).to eq(8)
    end

    it 'keeps the documented retry schedule of seven delays' do
      expect(described_class::DEFAULT_RETRY_DELAYS).to eq(
        [5.seconds, 5.minutes, 30.minutes, 2.hours, 5.hours, 10.hours, 10.hours]
      )
      expect(described_class::DEFAULT_RETRY_DELAYS.size).to eq(described_class::MAX_ATTEMPTS - 1)
    end

    it 'bounds the jitter to twenty percent' do
      expect(described_class::JITTER_RATIO).to eq(0.2)
    end

    it 'allows a fifteen second default http timeout' do
      expect(described_class::DEFAULT_HTTP_TIMEOUT_SECONDS).to eq(15)
      expect(described_class.delivery_lease_duration).to eq(60.seconds)
    end

    it 'allows three concurrent deliveries per endpoint' do
      expect(described_class::MAX_ACTIVE_DELIVERIES_PER_ENDPOINT).to eq(3)
    end
  end

  describe '.retry_delay' do
    it 'returns the exact base schedule when the jitter source is zero' do
      with_jitter(0.0)

      {
        1 => 5.seconds,
        2 => 5.minutes,
        3 => 30.minutes,
        4 => 2.hours,
        5 => 5.hours,
        6 => 10.hours,
        7 => 10.hours
      }.each do |attempts_made, base_delay|
        expect(described_class.retry_delay(attempts_made)).to eq(base_delay)
      end
    end

    it 'applies the bounded jitter on top of the base schedule' do
      with_jitter(0.5)

      expect(described_class.retry_delay(2)).to eq(5.minutes * 1.1)
    end

    it 'never returns a delay earlier than the base schedule and never exceeds the jitter window' do
      with_jitter(0.999)
      delayed = described_class.retry_delay(2)

      expect(delayed).to be > 5.minutes
      expect(delayed).to be < 5.minutes * 1.2
    end

    it 'returns nil once every attempt has been used' do
      expect(described_class.retry_delay(described_class::MAX_ATTEMPTS)).to be_nil
      expect(described_class.retry_delay(described_class::MAX_ATTEMPTS + 1)).to be_nil
    end

    it 'returns nil for a non positive attempt count' do
      expect(described_class.retry_delay(0)).to be_nil
      expect(described_class.retry_delay(-1)).to be_nil
    end

    context 'when a smaller attempt limit is stubbed for a unit test' do
      it 'stops scheduling retries at the stubbed limit' do
        stub_const('Webhooks::DeliveryPolicy::MAX_ATTEMPTS', 5)
        with_jitter(0.0)

        expect(described_class.retry_delay(4)).to eq(2.hours)
        expect(described_class.retry_delay(5)).to be_nil
      end
    end
  end

  describe '.retry_delay with a project override' do
    it 'uses the project schedule only on the pro plan' do
      pro_project = build(:project, plan: Project::PRO_PLAN, delivery_retry_delays_seconds: [10, 20, 40, 80, 160, 320, 640])
      with_jitter(0.0)

      expect(described_class.retry_delay(1, project: pro_project)).to eq(10.seconds)
      expect(described_class.retry_delay(3, project: pro_project)).to eq(40.seconds)
      expect(described_class.retry_delay(1, project: build(:project))).to eq(5.seconds)
    end
  end

  describe '.attempt_offsets' do
    it 'starts with an immediate attempt followed by the retry schedule' do
      with_jitter(0.0)

      expect(described_class.attempt_offsets).to eq([0.seconds] + described_class::DEFAULT_RETRY_DELAYS)
    end
  end

  describe '.capacity_retry_delay' do
    it 'returns the base capacity delay without jitter' do
      with_jitter(0.0)

      expect(described_class.capacity_retry_delay).to eq(described_class::CAPACITY_RETRY_DELAY)
    end

    it 'stays inside the bounded jitter window' do
      with_jitter(0.999)
      delayed = described_class.capacity_retry_delay

      expect(delayed).to be > described_class::CAPACITY_RETRY_DELAY
      expect(delayed).to be < described_class::CAPACITY_RETRY_DELAY * 1.2
    end
  end

  describe '.timeout_seconds_for' do
    it 'falls back to the default timeout unless a pro project overrides it' do
      expect(described_class.timeout_seconds_for(build(:project))).to eq(15)
      expect(described_class.timeout_seconds_for(build(:project, plan: Project::PRO_PLAN, delivery_timeout_seconds: 25)))
        .to eq(25)
      expect(described_class.timeout_seconds_for(nil)).to eq(15)
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

    it 'retries transient destination resolution failures' do
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
