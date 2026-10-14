require 'rails_helper'

describe ProjectInvitations::Accept, type: :operation do
  let(:owner) { create(:user) }
  let(:recipient) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let!(:invitation) { create(:project_invitation, project: project, invited_by: owner, recipient: recipient) }

  it 'adds the recipient as a maintainer and marks the invitation accepted' do
    described_class.call(invitation: invitation)

    expect(invitation.reload.status).to eq('accepted')
    expect(project.project_memberships.find_by(user: recipient).role).to eq('maintainer')
  end

  it 'rejects a non-pending invitation without creating a membership' do
    invitation.update!(status: :cancelled, cancelled_at: Time.current)

    expect { described_class.call(invitation: invitation) }.to raise_error(ApiError::UnprocessableEntityError)
    expect(project.project_memberships.exists?(user: recipient)).to be(false)
  end

  it 'keeps the invitation pending when membership creation fails' do
    allow_any_instance_of(ProjectMembership).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(ProjectMembership.new))

    expect { described_class.call(invitation: invitation) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(invitation.reload).to be_pending
  end

  describe 'notifications' do
    let(:recipient_stream) { NotificationsChannel.broadcasting_for(recipient) }
    let(:owner_stream) { NotificationsChannel.broadcasting_for(owner) }

    before do
      Notification.publish!(user: recipient, kind: :project_invitation_received,
                            title: 'Project invitation', message: 'You were invited.',
                            project_invitation: invitation)
      clear_cable_messages(recipient_stream)
      clear_cable_messages(owner_stream)
    end

    it 'removes the recipient pending notification' do
      described_class.call(invitation: invitation)

      expect(recipient.notifications.where(project_invitation: invitation)).to be_empty
      expect(cable_messages(recipient_stream)).to eq([{ 'type' => 'notification.removed' }])
    end

    it 'notifies the owner that the invitation was accepted' do
      described_class.call(invitation: invitation)

      notification = owner.notifications.sole
      expect(notification.kind).to eq('project_invitation_accepted')
      expect(notification.title).to eq('Invitation accepted')
      expect(notification.message).to eq("#{recipient.name} accepted your invitation to #{project.name}")
      expect(notification.target_url).to eq("/projects/#{project.id}")
      expect(notification.actor).to eq(recipient)
      expect(notification.project_invitation).to eq(invitation)
      expect(cable_messages(owner_stream)).to eq([{ 'type' => 'notification.created' }])
    end

    it 'does not notify or broadcast when the invitation is not pending' do
      invitation.update!(status: :cancelled, cancelled_at: Time.current)

      expect { described_class.call(invitation: invitation) }.to raise_error(ApiError::UnprocessableEntityError)
      expect(owner.notifications).to be_empty
      expect(cable_messages(owner_stream)).to be_empty
    end
  end
end
