module ProjectInvitations
  class Accept < ApplicationOperation
    def call(invitation:)
      ProjectInvitation.transaction do
        invitation.lock!
        raise ApiError::UnprocessableEntityError.new(message: 'Invitation can not be accepted') unless invitation.pending?

        invitation.project.project_memberships.create!(user_id: invitation.recipient_id, role: invitation.role)
        invitation.update!(status: :accepted, accepted_at: Time.current)
      end

      Notification.remove_for(invitation)
      notify_project_owner(invitation)

      invitation
    end

    private

    def notify_project_owner(invitation)
      Notification.publish!(
        user: invitation.project.owner,
        actor: invitation.recipient,
        project: invitation.project,
        project_invitation: invitation,
        kind: :project_invitation_accepted,
        title: 'Invitation accepted',
        message: "#{invitation.recipient.name} accepted your invitation to #{invitation.project.name}",
        target_url: "/projects/#{invitation.project_id}"
      )
    end
  end
end
