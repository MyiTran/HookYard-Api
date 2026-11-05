# == Schema Information
#
# Table name: endpoint_diagnoses
#
#  id                     :uuid             not null, primary key
#  analyzed_attempt_count :integer          default(0), not null
#  label                  :string           not null
#  model                  :string
#  source                 :string           not null
#  suggested_action       :text             not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  endpoint_id            :uuid             not null
#  project_id             :uuid             not null
#  requested_by_id        :uuid             not null
#
# Indexes
#
#  index_endpoint_diagnoses_on_endpoint_id                 (endpoint_id)
#  index_endpoint_diagnoses_on_endpoint_id_and_created_at  (endpoint_id,created_at)
#  index_endpoint_diagnoses_on_project_id                  (project_id)
#  index_endpoint_diagnoses_on_project_id_and_created_at   (project_id,created_at)
#  index_endpoint_diagnoses_on_requested_by_id             (requested_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#  fk_rails_...  (requested_by_id => users.id)
#
class EndpointDiagnosis < ApplicationRecord
  SOURCE_AI = Ai::Diagnosis::SOURCE_AI
  SOURCE_FALLBACK = Ai::Diagnosis::SOURCE_FALLBACK
  SOURCES = { ai: SOURCE_AI, fallback: SOURCE_FALLBACK }.freeze

  enum :source, SOURCES, validate: true

  belongs_to :endpoint
  belongs_to :project
  belongs_to :requested_by, class_name: 'User'

  validates :label, inclusion: { in: Ai::Diagnosis::LABELS }
  validates :suggested_action, presence: true, length: { maximum: Ai::Diagnosis::ACTION_MAX_LENGTH }
  validates :analyzed_attempt_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :endpoint_belongs_to_project

  private

  def endpoint_belongs_to_project
    return if endpoint.nil? || project.nil? || endpoint.project_id == project_id

    errors.add(:base, 'diagnosis endpoint must belong to the project')
  end
end
