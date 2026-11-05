# == Schema Information
#
# Table name: delivery_attempts
#
#  id                     :uuid             not null, primary key
#  attempt_number         :integer          default(1), not null
#  bodies_purged_at       :datetime
#  duration_ms            :integer
#  error_message          :text
#  error_type             :string
#  http_method            :string           default("POST"), not null
#  request_body           :text
#  request_headers        :jsonb            not null
#  request_url            :text             not null
#  response_body          :text
#  response_headers       :jsonb
#  response_status        :integer
#  signed_at              :datetime         not null
#  signing_secret_version :integer          not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  message_id             :uuid             not null
#  replay_item_id         :uuid
#  request_id             :string           not null
#  webhook_id             :string           not null
#
# Indexes
#
#  index_delivery_attempts_on_bodies_pending_purge           (created_at) WHERE ((bodies_purged_at IS NULL) AND ((response_status IS NOT NULL) OR (error_type IS NOT NULL)))
#  index_delivery_attempts_on_message_id                     (message_id)
#  index_delivery_attempts_on_message_id_and_attempt_number  (message_id,attempt_number) UNIQUE
#  index_delivery_attempts_on_message_id_and_created_at      (message_id,created_at)
#  index_delivery_attempts_on_replay_item_id                 (replay_item_id) UNIQUE
#  index_delivery_attempts_on_request_id                     (request_id)
#
# Foreign Keys
#
#  fk_rails_...  (message_id => messages.id) ON DELETE => cascade
#  fk_rails_...  (replay_item_id => replay_items.id) ON DELETE => nullify
#
class DeliveryAttempt < ApplicationRecord
  RESPONSE_BODY_MAX_BYTES = Webhooks::ResponseEvidence::RESPONSE_BODY_MAX_BYTES
  ERROR_MESSAGE_MAX_BYTES = Webhooks::ResponseEvidence::ERROR_MESSAGE_MAX_BYTES
  LEASE_EXPIRED_ERROR_TYPE = 'DeliveryLeaseExpired'
  LEASE_EXPIRED_MESSAGE = 'delivery lease expired before the attempt completed'
  SENSITIVE_HEADERS = Webhooks::ResponseEvidence::SENSITIVE_HEADERS
  EVIDENCE_FIELDS = %i[
    message_id attempt_number request_id webhook_id signing_secret_version signed_at
    request_url http_method request_headers request_body replay_item_id
  ].freeze

  class << self
    delegate :truncate_response_body, :truncate_error_message, :filter_headers,
             :normalize_external_text, :normalize_header_value, to: Webhooks::ResponseEvidence
  end

  belongs_to :message
  belongs_to :replay_item, optional: true

  scope :completed, -> { where('response_status IS NOT NULL OR error_type IS NOT NULL') }
  # Diagnosis must see every attempt the pipeline has finished with, including the
  # transport failures that never produced an HTTP status (timeout, DNS, TLS,
  # connection reset). An attempt without any terminal evidence is still in flight.
  scope :finished_for_diagnosis, lambda {
    where('response_status IS NOT NULL OR error_type IS NOT NULL OR error_message IS NOT NULL')
  }
  scope :newest_first, -> { reorder(created_at: :desc, attempt_number: :desc) }

  validates :attempt_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :attempt_number, uniqueness: { scope: :message_id }
  validates :request_id, :webhook_id, :request_url, :http_method, presence: true
  validates :request_body, presence: true, unless: :bodies_purged?
  validates :signing_secret_version, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :signed_at, presence: true
  validate :evidence_is_immutable, on: :update

  def succeeded?
    response_status.present? && response_status.between?(200, 299)
  end

  def transport_failed?
    error_type.present?
  end

  def completed?
    response_status.present? || error_type.present?
  end

  def replay?
    replay_item_id.present?
  end

  def bodies_purged?
    bodies_purged_at.present?
  end

  def status
    return 'succeeded' if succeeded?
    return 'failed' if transport_failed? || response_status.present?

    'in_progress'
  end

  def failure_category
    Webhooks::FailureCategory.for(error_type: error_type, response_status: response_status)
  end

  private

  def evidence_is_immutable
    return unless EVIDENCE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }

    errors.add(:base, 'delivery evidence can not be modified')
  end
end
