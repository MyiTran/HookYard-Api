require 'rails_helper'

describe ProjectInvitations::Cancel, type: :operation do
  let(:owner) { create(:user) }
  let(:recipient) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:invitation) { create(:project_invitation, project: project, invited_by: owner, recipient: recipient) }
  let(:recipient_stream) { NotificationsChannel.broadcasting_for(recipient) }
  let(:owner_stream) { NotificationsChannel.broadcasting_for(owner) }

  before do
    Notification.publish!(user: recipient, kind: :project_invitation_received,
                          title: 'Project invitation', message: 'You were invited.',
                          project_invitation: invitation)
    clear_cable_messages(recipient_stream)
    clear_cable_messages(owner_stream)
  end

  describe '.call' do
    context 'when the invitation is pending' do
      it 'marks the invitation as cancelled' do
        described_class.call(invitation: invitation)

        expect(invitation.reload).to be_cancelled
        expect(invitation.cancelled_at).to be_present
      end

      it 'removes the recipient notification and signals the removal' do
        described_class.call(invitation: invitation)

        expect(recipient.notifications.where(project_invitation: invitation)).to be_empty
        expect(cable_messages(recipient_stream)).to eq([{ 'type' => 'notification.removed' }])
      end

      it 'does not notify the owner' do
        described_class.call(invitation: invitation)

        expect(owner.notifications).to be_empty
        expect(cable_messages(owner_stream)).to be_empty
      end
    end

    context 'when the invitation is not pending' do
      before { invitation.update!(status: :accepted, accepted_at: Time.current) }

      it 'raises an unprocessable entity error and broadcasts nothing' do
        expect { described_class.call(invitation: invitation) }.to raise_error(ApiError::UnprocessableEntityError)
        expect(cable_messages(recipient_stream)).to be_empty
      end
    end
  end
end
