class Message
  module DeliveryLifecycle
    extend ActiveSupport::Concern

    included do
      scope :due_for_delivery, lambda { |at = Time.current|
        pending.where.not(next_retry_at: nil).where(next_retry_at: ..at)
      }
      scope :pending_without_retry_before, lambda { |at|
        pending.where(next_retry_at: nil).where(updated_at: ...at)
      }
      scope :with_expired_lease, lambda { |at = Time.current|
        delivering.where('delivery_lease_expires_at IS NULL OR delivery_lease_expires_at <= ?', at)
      }
      scope :with_active_lease, lambda { |at = Time.current|
        delivering.where(delivery_lease_expires_at: at..)
      }

      validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    end

    def terminal?
      succeeded? || failed?
    end

    def retries_available?
      attempt_count < Webhooks::DeliveryPolicy::MAX_ATTEMPTS
    end

    def retryable?
      pending? && retries_available?
    end

    def lease_active?(at = Time.current)
      delivery_lease_expires_at.present? && delivery_lease_expires_at > at
    end

    def lease_expired?(at = Time.current)
      delivering? && !lease_active?(at)
    end

    def mark_delivering!(lease_expires_at:, attempt_count:)
      update!(
        status: :delivering,
        attempt_count: attempt_count,
        next_retry_at: nil,
        delivery_lease_expires_at: lease_expires_at,
        terminal_at: nil
      )
    end

    def schedule_retry!(at:)
      update!(status: :pending, next_retry_at: at, delivery_lease_expires_at: nil)
    end

    def mark_succeeded!(at: Time.current)
      finish!(status: :succeeded, at: at)
    end

    def mark_failed!(at: Time.current)
      finish!(status: :failed, at: at)
    end

    private

    def finish!(status:, at:)
      update!(status: status, next_retry_at: nil, delivery_lease_expires_at: nil, terminal_at: at)
    end
  end
end
