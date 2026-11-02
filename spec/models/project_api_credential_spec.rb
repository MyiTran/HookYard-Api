require 'rails_helper'

describe ProjectApiCredential, type: :model do
  describe '.create_with_token!' do
    let(:project) { create(:project) }

    it 'returns the raw token once and persists only its digest' do
      credential, raw_token = described_class.create_with_token!(project: project, name: 'Producer')

      expect(raw_token).to start_with(ProjectApiCredential::TOKEN_PREFIX)
      expect(credential.token_digest).to eq(Digest::SHA256.hexdigest(raw_token))
      expect(credential.token_hint).to eq(raw_token.first(ProjectApiCredential::TOKEN_HINT_LENGTH))
      expect(credential.attributes.values).not_to include(raw_token)
    end
  end

  describe '.authenticate' do
    let(:credential) { create(:project_api_credential, raw_token: raw_token) }
    let(:raw_token) { described_class.generate_token }

    it 'returns the credential for a matching token' do
      expect(credential).to be_persisted

      expect(described_class.authenticate(raw_token)).to eq(credential)
    end

    it 'returns nil for an unknown token' do
      expect(described_class.authenticate(described_class.generate_token)).to be_nil
    end

    it 'returns nil for a blank token' do
      expect(described_class.authenticate(nil)).to be_nil
    end

    context 'when the credential is revoked' do
      before { credential.update!(revoked_at: Time.current) }

      it 'returns nil' do
        expect(described_class.authenticate(raw_token)).to be_nil
      end
    end
  end

  describe 'validations' do
    context 'when the name is missing' do
      it 'is invalid' do
        expect(build(:project_api_credential, name: '')).not_to be_valid
      end
    end

    context 'when the token digest is already used' do
      it 'is invalid' do
        existing = create(:project_api_credential)

        expect(build(:project_api_credential, token_digest: existing.token_digest)).not_to be_valid
      end
    end
  end
end
