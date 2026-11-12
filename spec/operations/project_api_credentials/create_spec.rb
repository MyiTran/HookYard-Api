require 'rails_helper'

describe ProjectApiCredentials::Create, type: :operation do
  describe '.call' do
    let(:project) { create(:project) }

    it 'creates a credential for the project and returns the raw token once' do
      credential, raw_token = described_class.call(project: project, name: 'Producer')

      expect(credential).to be_persisted
      expect(credential.project).to eq(project)
      expect(credential.name).to eq('Producer')
      expect(raw_token).to start_with(ProjectApiCredential::TOKEN_PREFIX)
      expect(credential.token_digest).to eq(Digest::SHA256.hexdigest(raw_token))
      expect(credential.attributes.values).not_to include(raw_token)
    end
  end
end
