# == Schema Information
#
# Table name: projects
#
#  id         :uuid             not null, primary key
#  name       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class Project < ApplicationRecord
  has_many :project_memberships, dependent: :destroy
  has_many :project_invitations, dependent: :destroy
  has_many :users, through: :project_memberships

  validates :name, presence: true

  def member?(user)
    return false if user.nil?

    project_memberships.exists?(user_id: user.id)
  end

  def owner
    project_memberships.find_by(role: :owner)&.user
  end

  def owner?(user)
    return false if user.nil?

    project_memberships.exists?(user_id: user.id, role: :owner)
  end
end
