module ProjectInvitations
  class Decline < ApplicationOperation
    def call(invitation:)
      ProjectInvitation.transaction do
        invitation.lock!
        raise ApiError::UnprocessableEntityError.new(message: 'Invitation can not be declined') unless invitation.pending?

        invitation.update!(status: :declined, declined_at: Time.current)
      end

      Notification.remove_for(invitation)
      Notification.publish!(
        user: invitation.project.owner,
        actor: invitation.recipient,
        project: invitation.project,
        project_invitation: invitation,
        kind: :project_invitation_declined,
        title: 'Invitation declined',
        message: "#{invitation.recipient.name} declined your invitation to #{invitation.project.name}",
        target_url: "/projects/#{invitation.project_id}"
      )

      invitation
    end
  end
end
