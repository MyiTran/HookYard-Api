require 'rails_helper'

describe ProjectApiCredentials::Revoke, type: :operation do
  describe '.call' do
    context 'when the credential is active' do
      it 'marks the credential as revoked' do
        credential = create(:project_api_credential)

        described_class.call(credential: credential)

        expect(credential.reload).to be_revoked
      end

      it 'stops authenticating the raw token' do
        credential, raw_token = ProjectApiCredential.create_with_token!(project: create(:project), name: 'Producer')

        described_class.call(credential: credential)

        expect(ProjectApiCredential.authenticate(raw_token)).to be_nil
      end
    end

    context 'when the credential is already revoked' do
      it 'keeps the original revocation time' do
        credential = create(:project_api_credential, revoked_at: 1.day.ago)
        revoked_at = credential.revoked_at

        described_class.call(credential: credential)

        expect(credential.reload.revoked_at).to be_within(1.second).of(revoked_at)
      end
    end
  end
end
