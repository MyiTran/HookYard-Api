module ProjectInvitations
  class Create < ApplicationOperation
    def call(project:, invited_by:, email:)
      recipient = User.find_by(email: email)
      raise ApiError::UnprocessableEntityError.new(message: 'Recipient not found') if recipient.nil?

      invitation = ProjectInvitation.transaction do
        project.project_invitations.create!(invited_by: invited_by, recipient: recipient, role: :maintainer)
      end

      Notification.publish!(
        user: recipient,
        actor: invited_by,
        project: project,
        project_invitation: invitation,
        kind: :project_invitation_received,
        title: 'Project invitation',
        message: "#{invited_by.name} invited you to #{project.name}",
        target_url: '/projects'
      )

      invitation
    end
  end
end
