require 'rails_helper'

describe Webhooks::CircuitPolicy, type: :model do
  describe 'defaults' do
    it 'opens the circuit after five consecutive failures' do
      expect(described_class::FAILURE_THRESHOLD).to eq(5)
    end

    it 'disables the endpoint after a five day open window' do
      expect(described_class.disable_window).to eq(5.days)
    end

    it 'protects the queue with a fixed capacity and warning threshold' do
      expect(described_class::QUEUE_CAPACITY).to eq(10_000)
      expect(described_class.warning_threshold).to eq(8_000)
      expect(described_class::RELEASE_BATCH_SIZE).to eq(100)
    end

    it 'owns the circuit probe cadence' do
      expect(described_class::PROBE_INTERVAL).to eq(5.minutes)
      expect(described_class.probe_interval).to eq(described_class::PROBE_INTERVAL)
    end
  end

  describe '.probe_interval' do
    it 'can be reduced for tests without touching the production default' do
      described_class.probe_interval = 1.minute

      expect(described_class.probe_interval).to eq(1.minute)
    end

    it 'is reset back to the production default' do
      described_class.probe_interval = 1.minute
      described_class.reset_probe_interval!

      expect(described_class.probe_interval).to eq(described_class::PROBE_INTERVAL)
    end
  end

  describe '.next_probe_at' do
    before do
      described_class.probe_interval = 5.minutes
      Webhooks::DeliveryPolicy.jitter_source = -> { 0 }
    end

    it 'uses the probe cadence instead of a retry delay' do
      from = Time.zone.local(2026, 1, 1, 12, 0, 0)

      expect(described_class.next_probe_at(from)).to eq(from + 5.minutes)
    end

    it 'keeps the probe inside the bounded positive jitter window' do
      from = Time.zone.local(2026, 1, 1, 12, 0, 0)
      Webhooks::DeliveryPolicy.jitter_source = -> { 1 }

      expect(described_class.next_probe_at(from)).to eq(from + 6.minutes)
    end
  end

  describe '.disable_window' do
    it 'can be reduced to seconds for tests' do
      described_class.disable_window = 2.seconds

      expect(described_class.disable_window).to eq(2.seconds)
    end

    it 'can be set to five seconds without leaving the example' do
      described_class.disable_window = 5.seconds

      expect(described_class.disable_window).to eq(5.seconds)
    end

    it 'is reset back to the five day production default' do
      described_class.disable_window = 5.seconds

      described_class.reset_disable_window!

      expect(described_class.disable_window).to eq(described_class::DEFAULT_DISABLE_WINDOW)
      expect(described_class.disable_window).to eq(5.days)
    end
  end

  describe 'environment configuration' do
    it 'falls back to the production defaults when the variables are absent' do
      with_circuit_env(described_class::DISABLE_WINDOW_ENV => nil, described_class::PROBE_INTERVAL_ENV => nil) do
        expect(described_class.disable_window).to eq(5.days)
        expect(described_class.probe_interval).to eq(described_class::PROBE_INTERVAL)
      end
    end

    it 'reads positive integer seconds from the environment' do
      with_circuit_env(described_class::DISABLE_WINDOW_ENV => '10', described_class::PROBE_INTERVAL_ENV => '5') do
        expect(described_class.disable_window).to eq(10.seconds)
        expect(described_class.probe_interval).to eq(5.seconds)
        expect(described_class.next_probe_at(Time.zone.local(2026, 1, 1, 12, 0, 0)))
          .to be_between(Time.zone.local(2026, 1, 1, 12, 0, 5), Time.zone.local(2026, 1, 1, 12, 0, 6))
      end
    end

    it 'prefers the test setter over the environment' do
      with_circuit_env(described_class::DISABLE_WINDOW_ENV => '10', described_class::PROBE_INTERVAL_ENV => '5') do
        described_class.disable_window = 2.seconds
        described_class.probe_interval = 1.minute

        expect(described_class.disable_window).to eq(2.seconds)
        expect(described_class.probe_interval).to eq(1.minute)
      end
    end

    it 'returns to the environment value after the test setter is reset' do
      with_circuit_env(described_class::DISABLE_WINDOW_ENV => '10', described_class::PROBE_INTERVAL_ENV => '5') do
        described_class.disable_window = 2.seconds
        described_class.probe_interval = 1.minute

        described_class.reset_disable_window!
        described_class.reset_probe_interval!

        expect(described_class.disable_window).to eq(10.seconds)
        expect(described_class.probe_interval).to eq(5.seconds)
      end
    end

    it 'ignores invalid values and warns without leaking the value' do
      allow(Rails.logger).to receive(:warn)

      ['', ' ', '0', '-5', 'abc', '5.5', '5s', '10 seconds', '+5'].each do |invalid|
        with_circuit_env(described_class::DISABLE_WINDOW_ENV => invalid) do
          expect(described_class.disable_window).to eq(5.days)
        end
      end

      with_circuit_env(described_class::PROBE_INTERVAL_ENV => '0') do
        expect(described_class.probe_interval).to eq(described_class::PROBE_INTERVAL)
      end

      expect(Rails.logger).to have_received(:warn).with(/#{described_class::DISABLE_WINDOW_ENV}/).at_least(:once)
      expect(Rails.logger).to have_received(:warn).with(/#{described_class::PROBE_INTERVAL_ENV}/).at_least(:once)
      expect(Rails.logger).not_to have_received(:warn).with(/10 seconds|abc|5\.5/)
    end
  end

  describe '.success?' do
    it 'treats only 2xx responses as success' do
      expect(described_class.success?(status_result(200))).to be(true)
      expect(described_class.success?(status_result(204))).to be(true)
      expect(described_class.success?(status_result(301))).to be(false)
      expect(described_class.success?(status_result(500))).to be(false)
      expect(described_class.success?(error_result('Net::ReadTimeout'))).to be(false)
    end
  end

  describe '.counted_failure?' do
    it 'counts retryable responses and transport failures' do
      expect(described_class.counted_failure?(status_result(408))).to be(true)
      expect(described_class.counted_failure?(status_result(429))).to be(true)
      expect(described_class.counted_failure?(status_result(503))).to be(true)
      expect(described_class.counted_failure?(error_result('Errno::ECONNRESET'))).to be(true)
    end

    it 'ignores redirect, non-retryable client errors and pre-request failures' do
      expect(described_class.counted_failure?(status_result(301))).to be(false)
      expect(described_class.counted_failure?(status_result(400))).to be(false)
      expect(described_class.counted_failure?(status_result(404))).to be(false)
      expect(described_class.counted_failure?(error_result('Webhooks::DestinationResolver::NotPubliclyRoutable'))).to be(false)
      expect(described_class.counted_failure?(error_result('Webhooks::Signer::InvalidSecret'))).to be(false)
      expect(described_class.counted_failure?(error_result(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE))).to be(false)
    end
  end

  describe '.capacity_available?' do
    it 'accepts deliveries while the queue stays below capacity' do
      expect(described_class.capacity_available?(described_class::QUEUE_CAPACITY - 1)).to be(true)
      expect(described_class.capacity_available?(described_class::QUEUE_CAPACITY)).to be(false)
      expect(described_class.capacity_available?(described_class::QUEUE_CAPACITY, 2)).to be(false)
    end
  end

  def with_circuit_env(variables)
    previous = variables.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    variables.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def status_result(status)
    Webhooks::HttpClient::Result.new(status: status, headers: {}, body: '')
  end

  def error_result(error_type)
    Webhooks::HttpClient::Result.new(error: 'failed', error_type: error_type)
  end
end
