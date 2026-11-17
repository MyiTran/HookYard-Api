require 'rails_helper'

describe ReplayRunPolicy, type: :policy do
  subject { described_class.new(user, replay_run) }

  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:replay_run) { build(:replay_run, project: project) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  context 'when the user is the project owner' do
    let(:user) { owner }

    it { is_expected.to permit_actions(%i[preview create show]) }
  end

  context 'when the user is a project maintainer' do
    let(:user) { maintainer }

    it { is_expected.to permit_actions(%i[preview create show]) }
  end

  context 'when the user is outside the project' do
    let(:user) { outsider }

    it { is_expected.to forbid_actions(%i[preview create show]) }
  end

  describe '.scope' do
    subject(:scope) { described_class::Scope.new(user, ReplayRun.all).resolve }

    before { replay_run.save! }

    context 'when the user is a project member' do
      let(:user) { maintainer }

      it { is_expected.to contain_exactly(replay_run) }
    end

    context 'when the user is outside the project' do
      let(:user) { outsider }

      it { is_expected.to be_empty }
    end
  end
end
