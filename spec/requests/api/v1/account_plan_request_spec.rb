require 'swagger_helper'

describe 'Accounts', type: :request do
  let(:account) { create(:user) }
  let(:other_account) { create(:user) }

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
