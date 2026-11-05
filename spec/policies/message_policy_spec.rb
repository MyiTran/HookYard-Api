require 'rails_helper'

describe MessagePolicy, type: :policy do
  subject { described_class.new(user, message) }

  let(:owner) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:message) { create(:message, project: project, endpoint: endpoint, status: :failed) }

  describe '#replay?' do
    context 'when the user is a project member' do
      let(:user) { owner }

      it { is_expected.to be_replay }
    end

    context 'when the user is not a project member' do
      let(:user) { outsider }

      it { is_expected.not_to be_replay }
    end
  end
end
