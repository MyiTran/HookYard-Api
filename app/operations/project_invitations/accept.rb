module ProjectInvitations
  class Accept < ApplicationOperation
    def call(invitation:)
      ProjectInvitation.transaction do
        invitation.lock!
        raise ApiError::UnprocessableEntityError.new(message: 'Invitation can not be accepted') unless invitation.pending?

        invitation.project.project_memberships.create!(user_id: invitation.recipient_id, role: invitation.role)
        invitation.update!(status: :accepted, accepted_at: Time.current)
        invitation
      end
    end
  end
end
