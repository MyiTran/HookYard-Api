# == Schema Information
#
# Table name: endpoints
#
#  id                             :uuid             not null, primary key
#  active                         :boolean          default(TRUE), not null
#  archived_at                    :datetime
#  circuit_disable_at             :datetime
#  circuit_failure_count          :integer          default(0), not null
#  circuit_next_probe_at          :datetime
#  circuit_opened_at              :datetime
#  circuit_probe_lease_expires_at :datetime
#  circuit_state                  :string           default("enabled"), not null
#  description                    :text
#  event_types                    :string           default([]), not null, is an Array
#  name                           :string           not null
#  queued_message_count           :integer          default(0), not null
#  url                            :string           not null
#  created_at                     :datetime         not null
#  updated_at                     :datetime         not null
#  project_id                     :uuid             not null
#
# Indexes
#
#  index_endpoints_on_archived_at                      (archived_at)
#  index_endpoints_on_circuit_state_and_next_probe_at  (circuit_state,circuit_next_probe_at)
#  index_endpoints_on_project_id                       (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class Endpoint < ApplicationRecord
  SIGNING_SECRET_BYTES = 32
  WILDCARD_EVENT_TYPE = '*'
  QUEUE_OK_STATE = 'ok'
  QUEUE_WARNING_STATE = 'warning'
  QUEUE_FULL_STATE = 'full'

  enum :circuit_state, { enabled: 'enabled', circuit_open: 'circuit_open', disabled: 'disabled' },
       default: :enabled, validate: true

  belongs_to :project
  has_many :endpoint_signing_secrets, dependent: :destroy
  has_many :messages, dependent: :destroy
  has_many :circuit_probes, dependent: :destroy

  scope :archived, -> { where.not(archived_at: nil) }
  scope :not_archived, -> { where(archived_at: nil) }
  scope :probe_due, lambda { |at = Time.current|
    circuit_open
      .where(circuit_next_probe_at: ..at)
      .where('circuit_probe_lease_expires_at IS NULL OR circuit_probe_lease_expires_at <= ?', at)
  }

  validates :name, presence: true
  validates :url, presence: true
  validate :url_must_be_http
  validate :event_types_must_be_consistent

  def archived?
    archived_at.present?
  end

  def subscribed_to?(event_type)
    event_types.include?(WILDCARD_EVENT_TYPE) || event_types.include?(event_type)
  end

  def current_signing_secret
    endpoint_signing_secrets.find { |secret| secret.retired_at.nil? }
  end

  def signing_secret_version
    current_signing_secret&.version
  end

  def has_signing_secret?
    endpoint_signing_secrets.any?
  end

  def rotate_signing_secret!
    with_lock do
      current_signing_secret&.update!(retired_at: Time.current)
      endpoint_signing_secrets.create!(version: next_signing_secret_version, secret: new_signing_secret)
    end
  end

  def queue_full?
    !Webhooks::CircuitPolicy.capacity_available?(queued_message_count)
  end

  def queue_state
    return QUEUE_FULL_STATE if queue_full?
    return QUEUE_WARNING_STATE if queued_message_count >= Webhooks::CircuitPolicy.warning_threshold

    QUEUE_OK_STATE
  end

  def held_message_count
    messages.pending.where.not(held_at: nil).count
  end

  def circuit_hold_reason
    return nil if enabled?

    if circuit_open?
      Webhooks::CircuitPolicy::HOLD_REASONS[:circuit_open]
    else
      Webhooks::CircuitPolicy::HOLD_REASONS[:disabled]
    end
  end

  def probe_in_flight?(at = Time.current)
    circuit_probe_lease_expires_at.present? && circuit_probe_lease_expires_at > at
  end

  def probe_due?(at = Time.current)
    circuit_open? && (circuit_next_probe_at.nil? || circuit_next_probe_at <= at)
  end

  def last_circuit_probe
    circuit_probes.order(created_at: :desc).first
  end

  def disable_window_elapsed?(at = Time.current)
    circuit_disable_at.present? && at >= circuit_disable_at
  end

  def register_circuit_failure!(at: Time.current)
    return unless enabled?

    increment!(:circuit_failure_count)
    open_circuit!(at: at) if circuit_failure_count >= Webhooks::CircuitPolicy::FAILURE_THRESHOLD
  end

  def open_circuit!(at: Time.current)
    update!(
      circuit_state: :circuit_open,
      circuit_opened_at: at,
      circuit_disable_at: at + Webhooks::CircuitPolicy.disable_window,
      circuit_next_probe_at: Webhooks::CircuitPolicy.next_probe_at(at),
      circuit_probe_lease_expires_at: nil
    )
    hold_pending_messages!(reason: Webhooks::CircuitPolicy::HOLD_REASONS[:circuit_open], at: at)
  end

  def close_circuit!
    return unless persisted?

    update!(
      circuit_state: :enabled,
      circuit_failure_count: 0,
      circuit_opened_at: nil,
      circuit_disable_at: nil,
      circuit_next_probe_at: nil,
      circuit_probe_lease_expires_at: nil
    )
  end

  def disable_circuit!(at: Time.current)
    update!(circuit_state: :disabled, circuit_next_probe_at: nil, circuit_probe_lease_expires_at: nil)
    hold_pending_messages!(reason: Webhooks::CircuitPolicy::HOLD_REASONS[:disabled], at: at, only_unheld: false)
  end

  def schedule_next_probe!(at: Time.current)
    update!(circuit_next_probe_at: Webhooks::CircuitPolicy.next_probe_at(at))
    hold_pending_messages!(reason: Webhooks::CircuitPolicy::HOLD_REASONS[:circuit_open], at: at)
  end

  def acquire_probe_lease!(at: Time.current)
    return false if probe_in_flight?(at)

    update!(circuit_probe_lease_expires_at: at + Webhooks::DeliveryPolicy.delivery_lease_duration)
    true
  end

  def release_probe_lease!
    update!(circuit_probe_lease_expires_at: nil) if circuit_probe_lease_expires_at.present?
  end

  def hold_pending_messages!(reason:, at: Time.current, only_unheld: true)
    scope = messages.pending
    scope = scope.where(held_at: nil) if only_unheld

    scope.update_all(
      held_at: at,
      hold_reason: reason,
      next_retry_at: nil,
      updated_at: at
    )
  end

  private

  def next_signing_secret_version
    (endpoint_signing_secrets.maximum(:version) || 0) + 1
  end

  def new_signing_secret
    "whsec_#{Base64.strict_encode64(SecureRandom.random_bytes(SIGNING_SECRET_BYTES))}"
  end

  def event_types_must_be_consistent
    return if event_types.blank?

    errors.add(:event_types, 'cannot contain blank event types') if event_types.any? { |type| type.to_s.strip.blank? }
    errors.add(:event_types, 'cannot contain duplicates') if event_types.uniq.length != event_types.length
    return unless event_types.include?(WILDCARD_EVENT_TYPE) && event_types.length > 1

    errors.add(:event_types, "cannot combine '#{WILDCARD_EVENT_TYPE}' with specific event types")
  end

  def url_must_be_http
    return if url.blank?

    uri = URI.parse(url)
    errors.add(:url, 'must be a public HTTP(S) URL') unless public_http_url?(uri)
  rescue URI::Error
    errors.add(:url, 'must be a valid HTTP(S) URL')
  end

  def public_http_url?(uri)
    uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && Webhooks::DestinationPolicy.public_host?(uri.host)
  end
end
