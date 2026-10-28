# == Schema Information
#
# Table name: messages
#
#  id                        :uuid             not null, primary key
#  attempt_count             :integer          default(0), not null
#  delivery_lease_expires_at :datetime
#  held_at                   :datetime
#  hold_reason               :string
#  next_retry_at             :datetime
#  queued_at                 :datetime
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
#  index_messages_on_endpoint_id_and_held_at     (endpoint_id,held_at)
#  index_messages_on_endpoint_status_and_lease   (endpoint_id,status,delivery_lease_expires_at)
#  index_messages_on_event_id                    (event_id)
#  index_messages_on_event_id_and_endpoint_id    (event_id,endpoint_id) UNIQUE
#  index_messages_on_pending_updated_at          (updated_at) WHERE ((status)::text = 'pending'::text)
#  index_messages_on_status_and_next_retry_at    (status,next_retry_at)
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#  fk_rails_...  (event_id => events.id) ON DELETE => cascade
#
class Message < ApplicationRecord
  PENDING_STATUS = 'pending'

  DELIVERY_STATE_QUEUED = 'queued'
  DELIVERY_STATE_SCHEDULED_RETRY = 'scheduled_retry'
  DELIVERY_STATE_HELD = 'held_by_circuit'
  DELIVERY_STATE_DELIVERING = 'delivering'
  DELIVERY_STATE_TERMINAL = 'terminal'

  DELIVERY_STATE_SCOPES = {
    DELIVERY_STATE_HELD => :held_by_circuit
  }.freeze

  attribute :last_attempt_at, :datetime
  attribute :last_response_status, :integer
  attribute :last_duration_ms, :integer
  attribute :last_error_type, :string

  enum :status, { pending: PENDING_STATUS, delivering: 'delivering', succeeded: 'succeeded', failed: 'failed' },
       default: :pending, validate: true

  belongs_to :event
  belongs_to :endpoint
  has_many :delivery_attempts, -> { order(:attempt_number) }, dependent: :destroy

  scope :held, -> { where.not(held_at: nil) }
  scope :not_held, -> { where(held_at: nil) }
  scope :held_by_circuit, -> { pending.held }
  scope :terminal, -> { where(status: %w[succeeded failed]) }

  scope :due_for_delivery, lambda { |at = Time.current|
    pending.not_held.where.not(next_retry_at: nil).where(next_retry_at: ..at)
  }
  scope :pending_without_retry_before, lambda { |at|
    pending.not_held.where(next_retry_at: nil).where(updated_at: ...at)
  }
  scope :with_expired_lease, lambda { |at = Time.current|
    delivering.where('delivery_lease_expires_at IS NULL OR delivery_lease_expires_at <= ?', at)
  }
  scope :with_active_lease, lambda { |at = Time.current|
    delivering.where(delivery_lease_expires_at: at..)
  }

  validates :attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :event_and_endpoint_share_project

  def self.delivery_state_scope(state)
    scope_name = DELIVERY_STATE_SCOPES[state.to_s]
    scope_name ? public_send(scope_name) : nil
  end

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

  def held?
    held_at.present?
  end

  def queue_counted?
    queued_at.present?
  end

  def delivery_state
    return DELIVERY_STATE_TERMINAL if terminal?
    return DELIVERY_STATE_DELIVERING if delivering?
    return DELIVERY_STATE_HELD if held?
    return DELIVERY_STATE_SCHEDULED_RETRY if next_retry_at.present?

    DELIVERY_STATE_QUEUED
  end

  def hold_summary
    return nil unless held?

    { reason: hold_reason, since: held_at, release_at: nil }
  end

  def failure_category
    Webhooks::FailureCategory.for(error_type: last_error_type, response_status: last_response_status)
  end

  def hold!(reason:, at: Time.current)
    update!(
      status: :pending,
      held_at: at,
      hold_reason: reason,
      next_retry_at: nil,
      delivery_lease_expires_at: nil
    )
  end

  def release_hold!
    update!(held_at: nil, hold_reason: nil) if held?
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
      terminal_at: nil,
      held_at: nil,
      hold_reason: nil
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
    update!(
      status: status,
      next_retry_at: nil,
      delivery_lease_expires_at: nil,
      terminal_at: at,
      held_at: nil,
      hold_reason: nil
    )
    release_queue_slot!
  end

  def release_queue_slot!
    return if queued_at.nil?

    released = self.class.where(id: id).where.not(queued_at: nil)
                    .update_all(queued_at: nil, updated_at: Time.current)
    return unless released == 1

    Endpoint.where(id: endpoint_id)
            .update_all('queued_message_count = queued_message_count - 1')
  end

  def event_and_endpoint_share_project
    return if event.nil? || endpoint.nil? || event.project_id == endpoint.project_id

    errors.add(:base, 'message event and endpoint must belong to the same project')
  end
end
