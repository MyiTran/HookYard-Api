# == Schema Information
#
# Table name: circuit_probes
#
#  id                     :uuid             not null, primary key
#  completed_at           :datetime
#  duration_ms            :integer
#  error_message          :text
#  error_type             :string
#  request_body           :text             not null
#  request_url            :text             not null
#  response_body          :text
#  response_headers       :jsonb
#  response_status        :integer
#  signing_secret_version :integer
#  started_at             :datetime         not null
#  status                 :string           default("pending"), not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  endpoint_id            :uuid             not null
#  request_id             :string           not null
#  webhook_id             :string           not null
#
# Indexes
#
#  index_circuit_probes_on_endpoint_id                 (endpoint_id)
#  index_circuit_probes_on_endpoint_id_and_created_at  (endpoint_id,created_at)
#  index_circuit_probes_on_endpoint_id_and_status      (endpoint_id,status)
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#
class CircuitProbe < ApplicationRecord
  LEASE_EXPIRED_ERROR_TYPE = 'CircuitProbeLeaseExpired'
  LEASE_EXPIRED_MESSAGE = 'circuit probe lease expired before the probe completed'
  REQUEST_EVIDENCE_FIELDS = %i[
    endpoint_id request_id webhook_id signing_secret_version started_at request_url request_body
  ].freeze

  enum :status, { pending: 'pending', succeeded: 'succeeded', failed: 'failed' }, default: :pending, validate: true

  belongs_to :endpoint

  validates :request_id, :webhook_id, :request_url, :request_body, presence: true
  validates :signing_secret_version, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :started_at, presence: true
  validate :request_evidence_is_immutable, on: :update

  def completed?
    completed_at.present?
  end

  private

  def request_evidence_is_immutable
    return unless REQUEST_EVIDENCE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }

    errors.add(:base, 'circuit probe request evidence can not be modified')
  end
end
