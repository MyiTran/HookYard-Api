# == Schema Information
#
# Table name: project_invitations
#
#  id            :uuid             not null, primary key
#  accepted_at   :datetime
#  cancelled_at  :datetime
#  declined_at   :datetime
#  role          :string           default("maintainer"), not null
#  status        :string           default("pending"), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  invited_by_id :uuid             not null
#  project_id    :uuid             not null
#  recipient_id  :uuid             not null
#
# Indexes
#
#  index_project_invitations_on_invited_by_id   (invited_by_id)
#  index_project_invitations_on_project_id      (project_id)
#  index_project_invitations_on_recipient_id    (recipient_id)
#  index_project_invitations_pending_recipient  (project_id,recipient_id) UNIQUE WHERE ((status)::text = 'pending'::text)
#
# Foreign Keys
#
#  fk_rails_...  (invited_by_id => users.id) ON DELETE => cascade
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#  fk_rails_...  (recipient_id => users.id) ON DELETE => cascade
#
class ProjectInvitation < ApplicationRecord
  enum :role, { maintainer: 'maintainer' }
  enum :status, { pending: 'pending', accepted: 'accepted', cancelled: 'cancelled', declined: 'declined' }

  belongs_to :project
  belongs_to :invited_by, class_name: 'User'
  belongs_to :recipient, class_name: 'User'

  validates :recipient_id, uniqueness: { scope: :project_id, conditions: -> { where(status: :pending) } }, if: :pending?
  validate :recipient_must_not_be_inviter, on: :create
  validate :recipient_must_not_be_member, on: :create

  private

  def recipient_must_not_be_inviter
    return if recipient_id.blank? || invited_by_id.blank?

    errors.add(:recipient, 'can not be the inviter') if recipient_id == invited_by_id
  end

  def recipient_must_not_be_member
    return if project.blank? || recipient_id.blank?

    errors.add(:recipient, 'is already a project member') if project.project_memberships.exists?(user_id: recipient_id)
  end
end
