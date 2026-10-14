require 'rails_helper'

describe ProjectInvitations::Create, type: :operation do
  let(:owner) { create(:user) }
  let(:recipient) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  it 'creates a pending maintainer invitation for the resolved user' do
    invitation = described_class.call(project: project, invited_by: owner, email: recipient.email)

    expect(invitation).to be_pending
    expect(invitation.role).to eq('maintainer')
    expect(invitation.recipient).to eq(recipient)
  end

  it 'raises when the recipient does not have an account' do
    expect { described_class.call(project: project, invited_by: owner, email: 'nobody@example.com') }
      .to raise_error(ApiError::UnprocessableEntityError)
  end

  describe 'notification' do
    let(:recipient_stream) { NotificationsChannel.broadcasting_for(recipient) }

    before { clear_cable_messages(recipient_stream) }

    it 'notifies the recipient about the invitation' do
      invitation = described_class.call(project: project, invited_by: owner, email: recipient.email)

      notification = recipient.notifications.sole
      expect(notification.kind).to eq('project_invitation_received')
      expect(notification.title).to eq('Project invitation')
      expect(notification.message).to eq("#{owner.name} invited you to #{project.name}")
      expect(notification.target_url).to eq('/projects')
      expect(notification.actor).to eq(owner)
      expect(notification.project).to eq(project)
      expect(notification.project_invitation).to eq(invitation)
      expect(notification.read_at).to be_nil
    end

    it 'broadcasts notification.created to the recipient only' do
      described_class.call(project: project, invited_by: owner, email: recipient.email)

      expect(cable_messages(recipient_stream)).to eq([{ 'type' => 'notification.created' }])
      expect(cable_messages(NotificationsChannel.broadcasting_for(owner))).to be_empty
    end

    it 'creates no notification and broadcasts nothing when the invitation is invalid' do
      create(:project_invitation, project: project, recipient: recipient)

      expect { described_class.call(project: project, invited_by: owner, email: recipient.email) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(Notification.count).to eq(0)
      expect(cable_messages(recipient_stream)).to be_empty
    end
  end
end
