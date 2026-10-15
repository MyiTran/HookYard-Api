require 'rails_helper'

describe ProjectInvitations::Decline, type: :operation do
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
      it 'marks the invitation as declined' do
        described_class.call(invitation: invitation)

        expect(invitation.reload).to be_declined
        expect(invitation.declined_at).to be_present
      end

      it 'does not create a project membership' do
        described_class.call(invitation: invitation)

        expect(project.project_memberships.exists?(user: recipient)).to be(false)
      end

      it 'removes the recipient notification and signals the removal' do
        described_class.call(invitation: invitation)

        expect(recipient.notifications.where(project_invitation: invitation)).to be_empty
        expect(cable_messages(recipient_stream)).to eq([{ 'type' => 'notification.removed' }])
      end

      it 'notifies the project owner' do
        described_class.call(invitation: invitation)

        notification = owner.notifications.sole
        expect(notification.kind).to eq('project_invitation_declined')
        expect(notification.title).to eq('Invitation declined')
        expect(notification.message).to eq("#{recipient.name} declined your invitation to #{project.name}")
        expect(notification.target_url).to eq("/projects/#{project.id}")
        expect(notification.actor).to eq(recipient)
        expect(notification.project_invitation).to eq(invitation)
        expect(cable_messages(owner_stream)).to eq([{ 'type' => 'notification.created' }])
      end
    end

    context 'when the invitation is not pending' do
      before { invitation.update!(status: :cancelled, cancelled_at: Time.current) }

      it 'raises an unprocessable entity error' do
        expect { described_class.call(invitation: invitation) }.to raise_error(ApiError::UnprocessableEntityError)
      end

      it 'does not notify the owner' do
        expect { described_class.call(invitation: invitation) }.to raise_error(ApiError::UnprocessableEntityError)

        expect(owner.notifications).to be_empty
        expect(cable_messages(owner_stream)).to be_empty
      end
    end
  end
end
