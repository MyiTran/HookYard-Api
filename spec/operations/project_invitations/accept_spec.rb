require 'rails_helper'

describe ProjectInvitations::Accept, type: :operation do
  let(:owner) { create(:user) }
  let(:recipient) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  it 'adds the recipient as a maintainer and marks the invitation accepted' do
    invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

    described_class.call(invitation: invitation)

    expect(invitation.reload.status).to eq('accepted')
    expect(project.project_memberships.find_by(user: recipient).role).to eq('maintainer')
  end

  it 'rejects a non-pending invitation without creating a membership' do
    invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient, status: :cancelled, cancelled_at: Time.current)

    expect { described_class.call(invitation: invitation) }.to raise_error(APIError::UnprocessableEntityError)
    expect(project.project_memberships.exists?(user: recipient)).to be(false)
  end

  it 'keeps the invitation pending when membership creation fails' do
    invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)
    allow_any_instance_of(ProjectMembership).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(ProjectMembership.new))

    expect { described_class.call(invitation: invitation) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(invitation.reload).to be_pending
  end
end
