class NotificationSerializer < ApplicationSerializer
  identifier :id

  fields :kind, :title, :message, :target_url, :read_at, :created_at, :project_id, :project_invitation_id
end
