# == Schema Information
#
# Table name: project_memberships
#
#  id         :uuid             not null, primary key
#  role       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  project_id :uuid             not null
#  user_id    :uuid             not null
#
# Indexes
#
#  index_project_memberships_on_project_id              (project_id)
#  index_project_memberships_on_project_id_and_user_id  (project_id,user_id) UNIQUE
#  index_project_memberships_on_project_id_owner        (project_id) UNIQUE WHERE ((role)::text = 'owner'::text)
#  index_project_memberships_on_user_id                 (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class ProjectMembership < ApplicationRecord
  enum :role, { owner: 'owner', maintainer: 'maintainer' }

  belongs_to :project
  belongs_to :user

  validates :user_id, uniqueness: { scope: :project_id }
end
