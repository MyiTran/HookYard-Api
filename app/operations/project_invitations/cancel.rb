module ProjectInvitations
  class Cancel < ApplicationOperation
    def call(invitation:)
      ProjectInvitation.transaction do
        invitation.lock!
        raise APIError::UnprocessableEntityError.new(message: 'Invitation can not be cancelled') unless invitation.pending?

        invitation.update!(status: :cancelled, cancelled_at: Time.current)
        invitation
      end
    end
  end
end
