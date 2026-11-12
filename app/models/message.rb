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
  include DeliveryLifecycle

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

  validate :event_and_endpoint_share_project
  validates :hold_reason, inclusion: { in: Webhooks::CircuitPolicy::HOLD_REASONS.values }, allow_nil: true
  validate :hold_state_is_consistent

  def self.delivery_state_scope(state)
    scope_name = DELIVERY_STATE_SCOPES[state.to_s]
    scope_name ? public_send(scope_name) : nil
  end

  def webhook_id
    "msg_#{id}"
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

  private

  def finish!(status:, at:)
    super
    release_queue_slot!
  end

  def release_queue_slot!
    return if queued_at.nil?

    released = self.class.where(id: id).where.not(queued_at: nil)
                    .update_all(queued_at: nil, updated_at: Time.current)
    return unless released == 1

    Endpoint.where(id: endpoint_id).where('queued_message_count > 0')
            .update_all('queued_message_count = queued_message_count - 1')
  end

  def hold_state_is_consistent
    unless held?
      errors.add(:held_at, 'must be present while the message has a hold reason') if hold_reason.present?
      return
    end

    errors.add(:status, 'must be pending while the message is held') unless pending?
    errors.add(:hold_reason, 'must be present while the message is held') if hold_reason.blank?
  end

  def event_and_endpoint_share_project
    return if event.nil? || endpoint.nil? || event.project_id == endpoint.project_id

    errors.add(:base, 'message event and endpoint must belong to the same project')
  end
end
