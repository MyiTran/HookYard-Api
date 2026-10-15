require 'rails_helper'

describe ProjectInvitation, type: :model do
  let(:owner) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  describe 'validations' do
    context 'when the recipient is the inviter' do
      it 'is invalid' do
        invitation = build(:project_invitation, project: project, invited_by: owner, recipient: owner)

        expect(invitation).not_to be_valid
        expect(invitation.errors[:recipient]).to be_present
      end
    end

    context 'when the recipient is already a member' do
      it 'is invalid' do
        member = create(:user)
        create(:project_membership, project: project, user: member, role: :maintainer)
        invitation = build(:project_invitation, project: project, invited_by: owner, recipient: member)

        expect(invitation).not_to be_valid
        expect(invitation.errors[:recipient]).to be_present
      end
    end

    context 'when a pending invitation already exists for the recipient' do
      let(:recipient) { create(:user) }

      it 'rejects a second pending invitation' do
        create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

        expect { create(:project_invitation, project: project, invited_by: owner, recipient: recipient) }
          .to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'when the previous invitation was cancelled' do
      let(:recipient) { create(:user) }

      it 'allows re-inviting the recipient' do
        create(:project_invitation, project: project, invited_by: owner, recipient: recipient, status: :cancelled)

        expect(build(:project_invitation, project: project, invited_by: owner, recipient: recipient)).to be_valid
      end
    end

    context 'when the previous invitation was declined' do
      let(:recipient) { create(:user) }

      it 'allows re-inviting the recipient' do
        create(:project_invitation, project: project, invited_by: owner, recipient: recipient, status: :declined, declined_at: Time.current)

        expect(build(:project_invitation, project: project, invited_by: owner, recipient: recipient)).to be_valid
      end
    end
  end
end
