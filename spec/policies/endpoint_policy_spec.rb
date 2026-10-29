describe EndpointPolicy, type: :policy do
  subject { described_class.new(user, endpoint) }

  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  context 'when the user is the project owner' do
    let(:user) { owner }

    it { is_expected.to permit_actions(%i[index show create update archive rotate_signing_secret re_enable]) }

    context 'when the endpoint circuit is disabled' do
      let(:endpoint) { create(:endpoint, project: project, circuit_state: 'disabled') }

      it { is_expected.to permit_action(:re_enable) }
    end

    context 'when the endpoint circuit is open' do
      let(:endpoint) { create(:endpoint, project: project, circuit_state: 'circuit_open') }

      it 'leaves the state machine to the operation' do
        expect(subject.re_enable?).to be(true)
      end
    end
  end

  context 'when the user is a project maintainer' do
    let(:user) { maintainer }

    it { is_expected.to permit_actions(%i[index show]) }
    it { is_expected.to forbid_actions(%i[create update archive rotate_signing_secret re_enable]) }
  end

  context 'when the user is outside the project' do
    let(:user) { outsider }

    it { is_expected.to forbid_actions(%i[index show create update archive rotate_signing_secret re_enable]) }
  end

  context 'when the endpoint is archived' do
    let(:endpoint) { create(:endpoint, project: project, archived_at: Time.current) }

    context 'when the user is the project owner' do
      let(:user) { owner }

      it { is_expected.to permit_actions(%i[index show archive]) }
      it { is_expected.to forbid_actions(%i[update rotate_signing_secret re_enable]) }

      context 'when the endpoint circuit is disabled' do
        let(:endpoint) { create(:endpoint, project: project, archived_at: Time.current, circuit_state: 'disabled') }

        it { is_expected.to forbid_action(:re_enable) }
      end
    end

    context 'when the user is a project maintainer' do
      let(:user) { maintainer }

      it { is_expected.to forbid_actions(%i[update archive rotate_signing_secret re_enable]) }
    end
  end
end
