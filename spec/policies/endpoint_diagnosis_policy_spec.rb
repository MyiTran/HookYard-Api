require 'rails_helper'

describe EndpointDiagnosisPolicy, type: :policy do
  subject { described_class.new(user, diagnosis) }

  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:diagnosis) { EndpointDiagnosis.new(endpoint: endpoint, project: project) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  describe '#create?' do
    context 'when the user is a project member' do
      let(:user) { maintainer }

      it 'is allowed' do
        expect(subject.create?).to be(true)
      end
    end

    context 'when the user is the project owner' do
      let(:user) { owner }

      it 'is allowed' do
        expect(subject.create?).to be(true)
      end
    end

    context 'when the user is not a project member' do
      let(:user) { outsider }

      it 'is denied' do
        expect(subject.create?).to be(false)
      end
    end
  end

  describe '#show?' do
    context 'when the user is a project member' do
      let(:user) { maintainer }

      it 'is allowed' do
        expect(subject.show?).to be(true)
      end
    end

    context 'when the user is the project owner' do
      let(:user) { owner }

      it 'is allowed' do
        expect(subject.show?).to be(true)
      end
    end

    context 'when the user is not a project member' do
      let(:user) { outsider }

      it 'is denied' do
        expect(subject.show?).to be(false)
      end
    end
  end
end
