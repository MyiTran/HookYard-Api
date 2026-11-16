require 'rails_helper'

describe IngestRejectionPolicy, type: :policy do
  subject { described_class.new(user, rejection) }

  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:rejection) { create(:ingest_rejection, project: project) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  context 'when the user is the project owner' do
    let(:user) { owner }

    it { is_expected.to permit_actions(%i[index show]) }
  end

  context 'when the user is a project maintainer' do
    let(:user) { maintainer }

    it { is_expected.to permit_actions(%i[index show]) }
  end

  context 'when the user is outside the project' do
    let(:user) { outsider }

    it { is_expected.to forbid_actions(%i[index show]) }
  end

  describe 'Scope' do
    it 'only resolves rejections of the project the user belongs to' do
      mine = rejection
      create(:ingest_rejection, project: create(:project, :with_owner, owner: outsider))

      resolved = described_class::Scope.new(maintainer, IngestRejection.all).resolve

      expect(resolved).to contain_exactly(mine)
    end

    it 'resolves nothing without a user' do
      expect(described_class::Scope.new(nil, IngestRejection.all).resolve).to be_empty
    end
  end
end
