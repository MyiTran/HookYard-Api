require 'rails_helper'

describe ProjectInvitation do
  let(:owner) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  it 'cannot invite the inviter' do
    invitation = build(:project_invitation, project: project, invited_by: owner, recipient: owner)

    expect(invitation).not_to be_valid
    expect(invitation.errors[:recipient]).to be_present
  end

  it 'cannot invite an existing member' do
    member = create(:user)
    create(:project_membership, project: project, user: member, role: :maintainer)
    invitation = build(:project_invitation, project: project, invited_by: owner, recipient: member)

    expect(invitation).not_to be_valid
    expect(invitation.errors[:recipient]).to be_present
  end

  it 'cannot create two pending invitations for the same recipient' do
    recipient = create(:user)
    create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

    expect { create(:project_invitation, project: project, invited_by: owner, recipient: recipient) }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'allows re-inviting after a cancellation' do
    recipient = create(:user)
    create(:project_invitation, project: project, invited_by: owner, recipient: recipient, status: :cancelled)

    expect(build(:project_invitation, project: project, invited_by: owner, recipient: recipient)).to be_valid
  end

  describe 'statuses' do
    it 'exposes pending, accepted and cancelled' do
      expect(described_class.statuses.keys).to contain_exactly('pending', 'accepted', 'cancelled')
    end
  end
end
