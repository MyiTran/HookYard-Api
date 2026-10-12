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
end
