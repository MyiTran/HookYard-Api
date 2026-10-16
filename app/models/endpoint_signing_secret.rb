# == Schema Information
#
# Table name: endpoint_signing_secrets
#
#  id          :uuid             not null, primary key
#  retired_at  :datetime
#  secret      :text             not null
#  version     :integer          not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  endpoint_id :uuid             not null
#
# Indexes
#
#  index_endpoint_signing_secrets_on_current_endpoint         (endpoint_id) UNIQUE WHERE (retired_at IS NULL)
#  index_endpoint_signing_secrets_on_endpoint_id              (endpoint_id)
#  index_endpoint_signing_secrets_on_endpoint_id_and_version  (endpoint_id,version) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#
class EndpointSigningSecret < ApplicationRecord
  encrypts :secret

  belongs_to :endpoint

  scope :current, -> { where(retired_at: nil) }

  validates :secret, presence: true
  validates :version, presence: true, uniqueness: { scope: :endpoint_id }

  def retired?
    retired_at.present?
  end
end
