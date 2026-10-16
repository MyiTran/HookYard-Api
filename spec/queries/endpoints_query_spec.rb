require 'rails_helper'

describe EndpointsQuery do
  let(:user) { create(:user) }
  let(:owned) { create(:project, :with_owner, owner: user) }
  let(:maintained) do
    create(:project).tap do |project|
      create(:project_membership, project: project, user: user, role: :maintainer)
    end
  end
  let(:scope) { EndpointPolicy::Scope.new(user, Endpoint).resolve }

  let!(:owned_endpoint) do
    create(:endpoint, project: owned, name: 'Payment Webhook', url: 'https://payments.example.com/hooks')
  end
  let!(:maintained_endpoint) do
    create(:endpoint, project: maintained, name: 'Billing Webhook', url: 'https://billing.example.com/hooks', active: false)
  end
  let!(:archived_endpoint) do
    create(:endpoint, project: owned, name: 'Archive Webhook', url: 'https://archive.example.com/hooks', archived_at: Time.current)
  end

  def run(**params)
    described_class.call(scope, **params)
  end

  describe 'without filters' do
    it 'returns endpoints from every accessible project' do
      expect(run).to contain_exactly(owned_endpoint, maintained_endpoint)
    end

    it 'excludes archived endpoints by default' do
      expect(run).not_to include(archived_endpoint)
    end
  end

  describe 'search' do
    it 'matches the name case-insensitively' do
      expect(run(q: 'payment')).to contain_exactly(owned_endpoint)
    end

    it 'matches the url' do
      expect(run(q: 'billing.example')).to contain_exactly(maintained_endpoint)
    end

    it 'returns no endpoint when nothing matches' do
      expect(run(q: 'nginx')).to be_empty
    end

    it 'ignores a blank search' do
      expect(run(q: '')).to contain_exactly(owned_endpoint, maintained_endpoint)
    end
  end

  describe 'project filter' do
    it 'returns only endpoints of the given project' do
      expect(run(project_id: owned.id)).to contain_exactly(owned_endpoint)
    end
  end

  describe 'active filter' do
    it 'returns only active endpoints' do
      expect(run(active: 'true')).to contain_exactly(owned_endpoint)
    end

    it 'returns only inactive endpoints' do
      expect(run(active: 'false')).to contain_exactly(maintained_endpoint)
    end
  end

  describe 'archive filter' do
    it 'returns only archived endpoints when archived is true' do
      expect(run(archived: 'true')).to contain_exactly(archived_endpoint)
    end

    it 'returns only non-archived endpoints when archived is false' do
      expect(run(archived: 'false')).to contain_exactly(owned_endpoint, maintained_endpoint)
    end
  end

  describe 'order' do
    it 'defaults to the newest first' do
      expect(run.to_a).to eq([maintained_endpoint, owned_endpoint])
    end

    it 'orders by name ascending' do
      expect(run(order: 'name_asc').pluck(:name)).to eq(['Billing Webhook', 'Payment Webhook'])
    end

    it 'falls back to the default for an unknown value' do
      expect(run(order: 'bogus').to_a).to eq([maintained_endpoint, owned_endpoint])
    end
  end

  describe 'tenant isolation' do
    it 'never returns an endpoint the user cannot access' do
      create(:endpoint, name: 'Payment Secret')

      expect(run(q: 'payment')).to contain_exactly(owned_endpoint)
    end
  end
end
