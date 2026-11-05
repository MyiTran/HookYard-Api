require 'rails_helper'

describe ReplayRunPolicy, type: :policy do
  subject { described_class.new(user, run) }

  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:run) { build(:replay_run, project: project, actor: owner) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  %i[preview? create? show?].each do |action|
    describe "##{action}" do
      context 'when the user is a project member' do
        let(:user) { maintainer }

        it 'is allowed' do
          expect(subject.public_send(action)).to be(true)
        end
      end

      context 'when the user is not a project member' do
        let(:user) { outsider }

        it 'is denied' do
          expect(subject.public_send(action)).to be(false)
        end
      end
    end
  end

  describe '.Scope' do
    it 'resolves only runs of accessible projects' do
      accessible = create(:replay_run, project: project, actor: owner)
      create(:replay_run, actor: outsider)

      resolved = described_class::Scope.new(maintainer, ReplayRun.all).resolve

      expect(resolved).to contain_exactly(accessible)
    end
  end
end
