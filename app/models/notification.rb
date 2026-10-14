# == Schema Information
#
# Table name: notifications
#
#  id                    :uuid             not null, primary key
#  kind                  :string           not null
#  message               :string           not null
#  read_at               :datetime
#  target_url            :string
#  title                 :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  actor_id              :uuid
#  project_id            :uuid
#  project_invitation_id :uuid
#  user_id               :uuid             not null
#
# Indexes
#
#  index_notifications_on_actor_id                (actor_id)
#  index_notifications_on_project_id              (project_id)
#  index_notifications_on_project_invitation_id   (project_invitation_id)
#  index_notifications_on_user_id                 (user_id)
#  index_notifications_on_user_id_and_created_at  (user_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (actor_id => users.id) ON DELETE => cascade
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#  fk_rails_...  (project_invitation_id => project_invitations.id) ON DELETE => cascade
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class Notification < ApplicationRecord
  enum :kind, {
    project_invitation_received: 'project_invitation_received',
    project_invitation_accepted: 'project_invitation_accepted',
    project_invitation_declined: 'project_invitation_declined'
  }

  belongs_to :user
  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :project, optional: true
  belongs_to :project_invitation, optional: true

  scope :recent, -> { where(created_at: 30.days.ago..).order(created_at: :desc) }
  scope :unread, -> { where(read_at: nil) }

  def self.publish!(user:, kind:, title:, message:, target_url: nil, actor: nil, project: nil, project_invitation: nil)
    notification = create!(user:, kind:, title:, message:, target_url:, actor:, project:, project_invitation:)
    NotificationsChannel.broadcast_created(notification)

    notification
  end

  def self.remove_for(project_invitation)
    where(project_invitation:).find_each do |notification|
      notification.destroy!
      NotificationsChannel.broadcast_removed(notification.user)
    end
  end
end
