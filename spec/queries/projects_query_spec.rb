require 'rails_helper'

describe ProjectsQuery do
  let(:user) { create(:user) }
  let!(:owned) { create(:project, :with_owner, owner: user, name: 'Payment API') }
  let!(:maintained) do
    create(:project, name: 'Billing API').tap do |project|
      create(:project_membership, project: project, user: user, role: :maintainer)
    end
  end
  let(:scope) { ProjectPolicy::Scope.new(user, Project).resolve }

  def run(**params)
    described_class.call(scope, user: user, **params)
  end

  describe 'without filters' do
    it 'returns every accessible project' do
      expect(run).to contain_exactly(owned, maintained)
    end
  end

  describe 'search' do
    it 'matches the project name case-insensitively' do
      expect(run(search: 'payment')).to contain_exactly(owned)
    end

    it 'returns no project when nothing matches' do
      expect(run(search: 'nginx')).to be_empty
    end

    it 'ignores a blank search' do
      expect(run(search: '')).to contain_exactly(owned, maintained)
    end
  end

  describe 'role' do
    it 'returns only projects owned by the user' do
      expect(run(role: 'owner')).to contain_exactly(owned)
    end

    it 'returns only projects maintained by the user' do
      expect(run(role: 'maintainer')).to contain_exactly(maintained)
    end

    it 'ignores an unsupported role' do
      expect(run(role: 'admin')).to contain_exactly(owned, maintained)
    end
  end

  describe 'order' do
    it 'defaults to the newest first' do
      expect(run.to_a).to eq([maintained, owned])
    end

    it 'orders oldest first' do
      expect(run(order: 'created_asc').to_a).to eq([owned, maintained])
    end

    it 'orders by name ascending' do
      expect(run(order: 'name_asc').pluck(:name)).to eq(['Billing API', 'Payment API'])
    end

    it 'falls back to the default for an unknown value' do
      expect(run(order: 'bogus').to_a).to eq([maintained, owned])
    end
  end

  describe 'combined filters' do
    it 'combines search, role and order' do
      create(:project, :with_owner, owner: user, name: 'Payment EU')

      expect(run(search: 'payment', role: 'owner', order: 'name_asc').pluck(:name)).to eq(['Payment API', 'Payment EU'])
    end
  end

  describe 'tenant isolation' do
    it 'never returns a project the user is not a member of' do
      create(:project, :with_owner, name: 'Payment Secret')

      expect(run(search: 'payment')).to contain_exactly(owned)
    end
  end
end
