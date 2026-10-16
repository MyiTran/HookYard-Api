module ProjectInvitations
  class Cancel < ApplicationOperation
    def call(invitation:)
      ProjectInvitation.transaction do
        invitation.lock!
        raise ApiError::UnprocessableEntityError.new(message: 'Invitation can not be cancelled') unless invitation.pending?

        invitation.update!(status: :cancelled, cancelled_at: Time.current)
      end

      Notification.remove_for(invitation)

      invitation
    end
  end
end
