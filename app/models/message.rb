# == Schema Information
#
# Table name: messages
#
#  id                        :uuid             not null, primary key
#  attempt_count             :integer          default(0), not null
#  delivery_lease_expires_at :datetime
#  next_retry_at             :datetime
#  status                    :string           default("pending"), not null
#  terminal_at               :datetime
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  endpoint_id               :uuid             not null
#  event_id                  :uuid             not null
#
# Indexes
#
#  index_messages_on_active_delivery_lease       (delivery_lease_expires_at) WHERE ((status)::text = 'delivering'::text)
#  index_messages_on_endpoint_id                 (endpoint_id)
#  index_messages_on_endpoint_id_and_created_at  (endpoint_id,created_at)
#  index_messages_on_endpoint_status_and_lease   (endpoint_id,status,delivery_lease_expires_at)
#  index_messages_on_event_id                    (event_id)
#  index_messages_on_event_id_and_endpoint_id    (event_id,endpoint_id) UNIQUE
#  index_messages_on_status_and_next_retry_at    (status,next_retry_at)
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#  fk_rails_...  (event_id => events.id) ON DELETE => cascade
#
class Message < ApplicationRecord
  PENDING_STATUS = 'pending'

  attribute :last_attempt_at, :datetime
  attribute :last_response_status, :integer
  attribute :last_duration_ms, :integer
  attribute :last_error_type, :string

  enum :status, { pending: PENDING_STATUS, delivering: 'delivering', succeeded: 'succeeded', failed: 'failed' },
       default: :pending, validate: true

  belongs_to :event
  belongs_to :endpoint
  has_many :delivery_attempts, -> { order(:attempt_number) }, dependent: :destroy

  scope :due_for_delivery, lambda { |at = Time.current|
    pending.where('next_retry_at IS NULL OR next_retry_at <= ?', at)
  }
  scope :with_expired_lease, lambda { |at = Time.current|
    delivering.where('delivery_lease_expires_at IS NULL OR delivery_lease_expires_at <= ?', at)
  }
  scope :with_active_lease, lambda { |at = Time.current|
    delivering.where(delivery_lease_expires_at: at..)
  }

  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :event_and_endpoint_share_project

  def webhook_id
    "msg_#{id}"
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

  def event_and_endpoint_share_project
    return if event.nil? || endpoint.nil? || event.project_id == endpoint.project_id

    errors.add(:base, 'message event and endpoint must belong to the same project')
  end
end
