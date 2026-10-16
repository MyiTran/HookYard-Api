module ProjectInvitations
  class Create < ApplicationOperation
    def call(project:, invited_by:, email:)
      recipient = find_recipient!(email)

      invitation = ProjectInvitation.transaction do
        project.project_invitations.create!(invited_by: invited_by, recipient: recipient, role: :maintainer)
      end

      notify_recipient(invitation)

      invitation
    end

    private

    def find_recipient!(email)
      User.find_by(email: email) || raise(ApiError::UnprocessableEntityError.new(message: 'Recipient not found'))
    end

    def notify_recipient(invitation)
      Notification.publish!(
        user: invitation.recipient,
        actor: invitation.invited_by,
        project: invitation.project,
        project_invitation: invitation,
        kind: :project_invitation_received,
        title: 'Project invitation',
        message: "#{invitation.invited_by.name} invited you to #{invitation.project.name}",
        target_url: '/projects'
      )
    end
  end
end
