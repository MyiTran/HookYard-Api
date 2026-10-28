# == Schema Information
#
# Table name: project_api_credentials
#
#  id           :uuid             not null, primary key
#  name         :string           not null
#  revoked_at   :datetime
#  token_digest :string           not null
#  token_hint   :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  project_id   :uuid             not null
#
# Indexes
#
#  index_project_api_credentials_on_project_id    (project_id)
#  index_project_api_credentials_on_token_digest  (token_digest) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class ProjectApiCredential < ApplicationRecord
  TOKEN_PREFIX = 'hky_'
  TOKEN_HINT_LENGTH = 12
  TOKEN_BYTES = 32

  belongs_to :project

  validates :name, presence: true
  validates :token_digest, presence: true, uniqueness: true
  validates :token_hint, presence: true

  def self.create_with_token!(project:, name:)
    raw_token = generate_token
    credential = create!(
      project: project,
      name: name,
      token_digest: digest_for(raw_token),
      token_hint: raw_token.first(TOKEN_HINT_LENGTH)
    )

    [credential, raw_token]
  end

  def self.authenticate(raw_token)
    return nil if raw_token.blank?

    credential = find_by(token_digest: digest_for(raw_token))
    credential unless credential.nil? || credential.revoked?
  end

  def self.generate_token
    "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(TOKEN_BYTES)}"
  end

  def self.digest_for(raw_token)
    Digest::SHA256.hexdigest(raw_token)
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current) unless revoked?

    self
  end
end
