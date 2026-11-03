# == Schema Information
#
# Table name: ingest_rejections
#
#  id                     :uuid             not null, primary key
#  event_type             :string
#  idempotency_key_digest :string
#  payload                :jsonb            not null
#  reason                 :string           not null
#  created_at             :datetime         not null
#  endpoint_id            :uuid
#  project_id             :uuid             not null
#
# Indexes
#
#  index_ingest_rejections_on_endpoint_id                (endpoint_id)
#  index_ingest_rejections_on_project_id                 (project_id)
#  index_ingest_rejections_on_project_id_and_created_at  (project_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => nullify
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class IngestRejection < ApplicationRecord
  QUEUE_CAPACITY_EXCEEDED = 'queue_capacity_exceeded'
  MONTHLY_DELIVERY_LIMIT_EXCEEDED = 'monthly_delivery_limit_exceeded'
  REASONS = [QUEUE_CAPACITY_EXCEEDED, MONTHLY_DELIVERY_LIMIT_EXCEEDED].freeze

  belongs_to :project
  belongs_to :endpoint, optional: true

  validates :reason, presence: true, inclusion: { in: REASONS }

  def self.digest_idempotency_key(raw_key)
    return nil if raw_key.blank?

    Digest::SHA256.hexdigest(raw_key.to_s)
  end
end
