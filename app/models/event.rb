# == Schema Information
#
# Table name: events
#
#  id                      :uuid             not null, primary key
#  event_type              :string           not null
#  idempotency_fingerprint :string           not null
#  idempotency_key         :string           not null
#  payload                 :jsonb            not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  project_id              :uuid             not null
#
# Indexes
#
#  index_events_on_project_id                      (project_id)
#  index_events_on_project_id_and_created_at       (project_id,created_at)
#  index_events_on_project_id_and_idempotency_key  (project_id,idempotency_key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class Event < ApplicationRecord
  EVENT_TYPE_MAX_LENGTH = 255
  IDEMPOTENCY_KEY_MAX_LENGTH = 255

  belongs_to :project
  has_many :messages, dependent: :destroy

  validates :event_type, presence: true, length: { maximum: EVENT_TYPE_MAX_LENGTH }
  validates :idempotency_key, presence: true, length: { maximum: IDEMPOTENCY_KEY_MAX_LENGTH }
  validates :idempotency_fingerprint, presence: true
  validate :payload_must_be_object

  before_validation :assign_idempotency_fingerprint

  def self.fingerprint_for(event_type:, payload:)
    Digest::SHA256.hexdigest(Oj.dump({ type: event_type, payload: canonicalize(payload) }, mode: :compat))
  end

  def self.canonicalize(value)
    case value
    when Hash then value.map { |key, nested| [key.to_s, canonicalize(nested)] }.sort_by(&:first).to_h
    when Array then value.map { |nested| canonicalize(nested) }
    else value
    end
  end

  private

  def assign_idempotency_fingerprint
    return if event_type.blank? || !payload.is_a?(Hash)

    self.idempotency_fingerprint = self.class.fingerprint_for(event_type: event_type, payload: payload)
  end

  def payload_must_be_object
    errors.add(:payload, 'must be a JSON object') unless payload.is_a?(Hash)
  end
end
