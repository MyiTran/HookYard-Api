# == Schema Information
#
# Table name: replay_items
#
#  id                        :uuid             not null, primary key
#  completed_at              :datetime
#  delivery_lease_expires_at :datetime
#  error_message             :text
#  error_type                :string
#  hold_reason               :string
#  skip_reason               :string
#  started_at                :datetime
#  status                    :string           default("queued"), not null
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  endpoint_id               :uuid             not null
#  message_id                :uuid             not null
#  replay_run_id             :uuid             not null
#
# Indexes
#
#  index_replay_items_on_active_message            (message_id) UNIQUE WHERE ((status)::text = ANY ((ARRAY['queued'::character varying, 'held'::character varying, 'delivering'::character varying])::text[]))
#  index_replay_items_on_endpoint_id               (endpoint_id)
#  index_replay_items_on_endpoint_id_and_status    (endpoint_id,status)
#  index_replay_items_on_message_id                (message_id)
#  index_replay_items_on_replay_run_id             (replay_run_id)
#  index_replay_items_on_replay_run_id_and_status  (replay_run_id,status)
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#  fk_rails_...  (message_id => messages.id) ON DELETE => cascade
#  fk_rails_...  (replay_run_id => replay_runs.id) ON DELETE => cascade
#
class ReplayItem < ApplicationRecord
  QUEUED_STATUS = 'queued'
  HELD_STATUS = 'held'
  DELIVERING_STATUS = 'delivering'
  SUCCEEDED_STATUS = 'succeeded'
  FAILED_STATUS = 'failed'
  SKIPPED_STATUS = 'skipped'

  ACTIVE_STATUSES = [QUEUED_STATUS, HELD_STATUS, DELIVERING_STATUS].freeze
  TERMINAL_STATUSES = [SUCCEEDED_STATUS, FAILED_STATUS, SKIPPED_STATUS].freeze
  STATUSES = {
    queued: QUEUED_STATUS,
    held: HELD_STATUS,
    delivering: DELIVERING_STATUS,
    succeeded: SUCCEEDED_STATUS,
    failed: FAILED_STATUS,
    skipped: SKIPPED_STATUS
  }.freeze

  HOLD_REASON_CIRCUIT_OPEN = 'endpoint_circuit_open'
  HOLD_REASONS = [HOLD_REASON_CIRCUIT_OPEN].freeze

  SKIP_REASON_ENDPOINT_ARCHIVED = 'endpoint_archived'
  SKIP_REASON_ENDPOINT_PAUSED = 'endpoint_paused'
  SKIP_REASON_ENDPOINT_DISABLED = 'endpoint_disabled'
  SKIP_REASONS = [
    SKIP_REASON_ENDPOINT_ARCHIVED,
    SKIP_REASON_ENDPOINT_PAUSED,
    SKIP_REASON_ENDPOINT_DISABLED
  ].freeze

  MISSING_SECRET_ERROR_TYPE = 'ReplaySigningSecretMissing'
  MISSING_SECRET_MESSAGE = 'endpoint has no current signing secret'

  enum :status, STATUSES, default: :queued, validate: true

  belongs_to :replay_run
  belongs_to :message
  belongs_to :endpoint
  has_one :delivery_attempt, dependent: :nullify

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :with_active_lease, lambda { |at = Time.current|
    delivering.where(delivery_lease_expires_at: at..)
  }

  validates :hold_reason, inclusion: { in: HOLD_REASONS }, allow_nil: true
  validates :skip_reason, inclusion: { in: SKIP_REASONS }, allow_nil: true
  validate :hold_reason_matches_status
  validate :skip_reason_matches_status
  validate :endpoint_matches_message

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def lease_active?(at = Time.current)
    delivery_lease_expires_at.present? && delivery_lease_expires_at > at
  end

  def mark_queued!
    update!(status: :queued, hold_reason: nil, skip_reason: nil)
  end

  def mark_held!(reason:, at: Time.current)
    update!(status: :held, hold_reason: reason, skip_reason: nil, delivery_lease_expires_at: nil, updated_at: at)
  end

  def mark_delivering!(lease_expires_at:, at: Time.current)
    update!(
      status: :delivering,
      hold_reason: nil,
      skip_reason: nil,
      delivery_lease_expires_at: lease_expires_at,
      started_at: started_at || at
    )
  end

  def mark_succeeded!(at: Time.current)
    update!(
      status: :succeeded,
      hold_reason: nil,
      skip_reason: nil,
      completed_at: at,
      delivery_lease_expires_at: nil,
      error_type: nil,
      error_message: nil
    )
  end

  def mark_failed!(at: Time.current, error_type: nil, error_message: nil)
    update!(
      status: :failed,
      hold_reason: nil,
      skip_reason: nil,
      completed_at: at,
      delivery_lease_expires_at: nil,
      error_type: error_type,
      error_message: error_message
    )
  end

  def mark_skipped!(reason:, at: Time.current)
    update!(
      status: :skipped,
      skip_reason: reason,
      hold_reason: nil,
      completed_at: at,
      delivery_lease_expires_at: nil
    )
  end

  private

  def hold_reason_matches_status
    if held?
      errors.add(:hold_reason, 'is required while the item is held') if hold_reason.blank?
    elsif hold_reason.present?
      errors.add(:hold_reason, 'is only kept while the item is held')
    end
  end

  def skip_reason_matches_status
    if skipped?
      errors.add(:skip_reason, 'is required while the item is skipped') if skip_reason.blank?
    elsif skip_reason.present?
      errors.add(:skip_reason, 'is only kept while the item is skipped')
    end
  end

  def endpoint_matches_message
    return if message.nil? || endpoint.nil? || message.endpoint_id == endpoint_id

    errors.add(:base, 'replay item endpoint must match the message endpoint')
  end
end
