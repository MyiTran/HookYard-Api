module Webhooks
  # Single source of truth for outbound delivery timing, retry and concurrency
  # rules. Every delivery attempt uses these values so retry behavior stays
  # predictable across workers and restarts.
  class DeliveryPolicy
    DEFAULT_HTTP_TIMEOUT_SECONDS = 15
    MIN_HTTP_TIMEOUT_SECONDS = 1
    MAX_HTTP_TIMEOUT_SECONDS = 30
    MAX_ATTEMPTS = 8

    # Delay inserted after the given attempt: attempt 1 is immediate, so the
    # first retry waits 5 seconds and the last retry waits 10 hours.
    DEFAULT_RETRY_DELAYS = [
      5.seconds,
      5.minutes,
      30.minutes,
      2.hours,
      5.hours,
      10.hours,
      10.hours
    ].freeze

    JITTER_RATIO = 0.2
    MAX_ACTIVE_DELIVERIES_PER_ENDPOINT = 3
    CAPACITY_RETRY_DELAY = 15.seconds
    DELIVERY_LEASE_SECONDS = DEFAULT_HTTP_TIMEOUT_SECONDS * 4

    RETRYABLE_HTTP_STATUSES = [408, 429].freeze
    RETRYABLE_ERROR_TYPES = %w[
      Timeout::Error
      Net::OpenTimeout
      Net::ReadTimeout
      Net::WriteTimeout
      Webhooks::DestinationResolver::ResolutionFailed
      Errno::ECONNABORTED
      Errno::ECONNREFUSED
      Errno::ECONNRESET
      Errno::EHOSTUNREACH
      Errno::ENETUNREACH
      Errno::EPIPE
      Errno::ETIMEDOUT
      SocketError
      OpenSSL::SSL::SSLError
      IOError
      EOFError

    ].freeze

    class << self
      attr_writer :jitter_source

      def jitter_source
        @jitter_source ||= -> { rand }
      end

      def reset_jitter_source!
        @jitter_source = nil
      end

      def attempt_offsets(project: nil)
        [0.seconds] + retry_delays_for(project)
      end

      def retry_delays_for(project)
        configured = project&.pro? ? project.delivery_retry_delays_seconds : nil
        return DEFAULT_RETRY_DELAYS if configured.blank?

        configured.map { |seconds| seconds.seconds }
      end

      def timeout_seconds_for(project)
        configured = project&.pro? ? project.delivery_timeout_seconds : nil
        configured || DEFAULT_HTTP_TIMEOUT_SECONDS
      end

      def retryable?(result)
        return retryable_error?(result.error_type) if result.error?

        retryable_status?(result.status)
      end

      def retryable_status?(status)
        return false if status.nil?

        RETRYABLE_HTTP_STATUSES.include?(status) || status >= 500
      end

      def retryable_error?(error_type)
        RETRYABLE_ERROR_TYPES.include?(error_type.to_s)
      end

      def retry_delay(attempts_made, project: nil)
        return nil if attempts_made < 1 || attempts_made >= MAX_ATTEMPTS

        base_delay = retry_delays_for(project)[attempts_made - 1]
        return nil if base_delay.nil?

        jittered(base_delay)
      end

      def capacity_retry_delay
        jittered(CAPACITY_RETRY_DELAY)
      end

      def delivery_lease_duration
        DELIVERY_LEASE_SECONDS.seconds
      end

      def jittered(base_duration)
        base_duration * (1 + (JITTER_RATIO * jitter_source.call))
      end
    end
  end
end
