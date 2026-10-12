module ProjectInvitations
  class Create < ApplicationOperation
    def call(project:, invited_by:, email:)
      recipient = User.find_by(email: email)
      raise APIError::UnprocessableEntityError.new(message: 'Recipient not found') if recipient.nil?

      invitation = ProjectInvitation.transaction do
        project.project_invitations.create!(invited_by: invited_by, recipient: recipient, role: :maintainer)
      end

      invitation
    end
  end
end
