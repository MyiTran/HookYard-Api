class ProjectInvitationSerializer < ApplicationSerializer
  identifier :id

  fields :role, :status, :created_at, :accepted_at, :cancelled_at, :declined_at

  field :project do |invitation|
    { id: invitation.project_id, name: invitation.project.name }
  end

  field :invited_by do |invitation|
    user_summary(invitation.invited_by)
  end

  field :recipient do |invitation|
    user_summary(invitation.recipient)
  end

  def self.user_summary(user)
    { id: user.id, first_name: user.first_name, last_name: user.last_name }
  end
end
