require 'swagger_helper'

describe 'Accounts', type: :request do
  let(:account) { create(:user) }
  let(:other_account) { create(:user) }

  describe 'GET /api/v1/account' do
    it 'returns the plan and zero usage for an account that owns no projects' do
      get '/api/v1/account', headers: auth_headers(account)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['id']).to eq(account.id)
      expect(body['plan']).to eq(User::FREE_PLAN)
      expect(body['project_limit']).to eq(2)
      expect(body['endpoint_limit_per_project']).to eq(3)
      expect(body['monthly_delivery_limit']).to eq(10_000)
      expect(body['usage']).to include(
        'project_count' => 0,
        'deliveries_this_period' => 0,
        'deliveries_remaining' => 10_000
      )
      expect(body['usage']['period_starts_at']).to eq(UserUsagePeriod.period_starts_at.iso8601)
      expect(body['usage']['period_ends_at']).to eq(UserUsagePeriod.period_ends_at.iso8601)
    end

    it 'returns the limits of the account plan' do
      account.update!(plan: User::PRO_PLAN)

      get '/api/v1/account', headers: auth_headers(account)

      body = JSON.parse(response.body)
      expect(body['plan']).to eq(User::PRO_PLAN)
      expect(body['project_limit']).to eq(10)
      expect(body['endpoint_limit_per_project']).to eq(50)
      expect(body['monthly_delivery_limit']).to eq(500_000)
    end

    it 'returns the own plan and usage of an account that only belongs to another owner project' do
      other_account.update!(plan: User::PRO_PLAN)
      project = create(:project, :with_owner, owner: other_account)
      create(:project_membership, project: project, user: account, role: :maintainer)
      UserUsagePeriod.reserve_deliveries(user: other_account, quantity: 7, limit: 500_000)

      get '/api/v1/account', headers: auth_headers(account)

      body = JSON.parse(response.body)
      expect(body['id']).to eq(account.id)
      expect(body['plan']).to eq(User::FREE_PLAN)
      expect(body['usage']).to include(
        'project_count' => 0,
        'deliveries_this_period' => 0,
        'deliveries_remaining' => 10_000
      )

      get '/api/v1/account', headers: auth_headers(other_account)

      expect(JSON.parse(response.body)['usage']).to include(
        'project_count' => 1,
        'deliveries_this_period' => 7,
        'deliveries_remaining' => 499_993
      )
    end

    it 'includes both plan options for a free account' do
      get '/api/v1/account', headers: auth_headers(account)

      available_plans = JSON.parse(response.body)['available_plans']
      expect(available_plans).to eq(
        [
          { 'plan' => User::FREE_PLAN, 'project_limit' => 2, 'endpoint_limit_per_project' => 3,
            'monthly_delivery_limit' => 10_000 },
          { 'plan' => User::PRO_PLAN, 'project_limit' => 10, 'endpoint_limit_per_project' => 50,
            'monthly_delivery_limit' => 500_000 }
        ]
      )
      expect(available_plans.first.keys).to contain_exactly(
        'plan', 'project_limit', 'endpoint_limit_per_project', 'monthly_delivery_limit'
      )
    end

    it 'includes both plan options for a pro account' do
      account.update!(plan: User::PRO_PLAN)

      get '/api/v1/account', headers: auth_headers(account)

      body = JSON.parse(response.body)
      expect(body['plan']).to eq(User::PRO_PLAN)
      expect(body['available_plans'].pluck('plan')).to eq([User::FREE_PLAN, User::PRO_PLAN])
      expect(body['available_plans'].second).to include(
        'project_limit' => 10,
        'endpoint_limit_per_project' => 50,
        'monthly_delivery_limit' => 500_000
      )
    end

    it 'never renders another account when the params carry an id' do
      get '/api/v1/account', params: { id: other_account.id, user_id: other_account.id },
                             headers: auth_headers(account)

      expect(JSON.parse(response.body)['id']).to eq(account.id)
    end

    it 'does not create a usage period while the account only views its plan' do
      expect do
        get '/api/v1/account', headers: auth_headers(account)
      end.not_to change(UserUsagePeriod, :count)
    end

    it 'requires authentication' do
      get '/api/v1/account'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'PATCH /api/v1/account/plan' do
    it 'lets the account switch itself to the pro plan without payment' do
      patch '/api/v1/account/plan', params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(account), as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['id']).to eq(account.id)
      expect(body['plan']).to eq(User::PRO_PLAN)
      expect(body['project_limit']).to eq(10)
      expect(body['endpoint_limit_per_project']).to eq(50)
      expect(body['monthly_delivery_limit']).to eq(500_000)
      expect(account.reload.plan).to eq(User::PRO_PLAN)
    end

    it 'lets the account switch back to the free plan' do
      account.update!(plan: User::PRO_PLAN)

      patch '/api/v1/account/plan', params: { account: { plan: User::FREE_PLAN } }, headers: auth_headers(account), as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['plan']).to eq(User::FREE_PLAN)
      expect(body['project_limit']).to eq(2)
      expect(body['endpoint_limit_per_project']).to eq(3)
      expect(body['monthly_delivery_limit']).to eq(10_000)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'renders the account usage of the current period' do
      create_list(:project, 2, :with_owner, owner: account)
      UserUsagePeriod.reserve_deliveries(user: account, quantity: 4, limit: 10_000)

      patch '/api/v1/account/plan', params: { account: { plan: User::FREE_PLAN } }, headers: auth_headers(account), as: :json

      usage = JSON.parse(response.body)['usage']
      expect(usage).to include(
        'project_count' => 2,
        'deliveries_this_period' => 4,
        'deliveries_remaining' => 9_996
      )
      expect(usage['period_starts_at']).to eq(UserUsagePeriod.period_starts_at.iso8601)
      expect(usage['period_ends_at']).to eq(UserUsagePeriod.period_ends_at.iso8601)
    end

    it 'never changes another account through the self service route' do
      patch '/api/v1/account/plan', params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(account), as: :json

      expect(other_account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'rejects an unknown plan' do
      patch '/api/v1/account/plan', params: { account: { plan: 'enterprise' } }, headers: auth_headers(account), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'requires authentication' do
      patch '/api/v1/account/plan', params: { account: { plan: User::PRO_PLAN } }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end
  end
end
