module Webhooks
  # Central circuit-breaker and queue-protection rules for webhook delivery.
  # Keeping the limits here makes the endpoint lifecycle deterministic and lets
  # specs shrink the disable window and probe cadence without touching
  # production behavior.
  class CircuitPolicy
    FAILURE_THRESHOLD = 5
    DEFAULT_DISABLE_WINDOW = 5.days
    QUEUE_CAPACITY = 10_000
    WARNING_THRESHOLD_RATIO = 0.8
    RELEASE_BATCH_SIZE = 100
    PROBE_INTERVAL = 5.minutes
    DISABLE_WINDOW_ENV = 'WEBHOOK_CIRCUIT_DISABLE_WINDOW_SECONDS'
    PROBE_INTERVAL_ENV = 'WEBHOOK_CIRCUIT_PROBE_INTERVAL_SECONDS'
    POSITIVE_INTEGER = /\A\d+\z/

    HOLD_REASONS = {
      circuit_open: 'endpoint_circuit_open',
      disabled: 'endpoint_disabled'
    }.freeze

    class << self
      attr_writer :disable_window, :probe_interval

      def disable_window
        @disable_window || env_seconds(DISABLE_WINDOW_ENV) || DEFAULT_DISABLE_WINDOW
      end

      def reset_disable_window!
        @disable_window = nil
      end

      def probe_interval
        @probe_interval || env_seconds(PROBE_INTERVAL_ENV) || PROBE_INTERVAL
      end

      def reset_probe_interval!
        @probe_interval = nil
      end

      def success?(result)
        !result.error? && result.status.to_i.between?(200, 299)
      end

      def counted_failure?(result)
        DeliveryPolicy.retryable?(result)
      end

      def next_probe_at(from = Time.current)
        from + DeliveryPolicy.jittered(probe_interval)
      end

      def warning_threshold
        (QUEUE_CAPACITY * WARNING_THRESHOLD_RATIO).ceil
      end

      def capacity_available?(queued_count, incoming = 1)
        queued_count + incoming <= QUEUE_CAPACITY
      end

      private

      def env_seconds(key)
        raw = ENV.fetch(key, nil)

        if raw.blank?
          return nil
        end

        seconds = parse_positive_integer(raw)
        return seconds.seconds if seconds

        Rails.logger&.warn("Ignoring #{key}: expected a positive integer number of seconds")
        nil
      end

      def parse_positive_integer(raw)
        value = raw.to_s.strip
        return nil unless value.match?(POSITIVE_INTEGER)

        seconds = value.to_i
        seconds.positive? ? seconds : nil
      end
    end
  end
end
