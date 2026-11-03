require 'swagger_helper'

describe 'Admin::Accounts', type: :request do
  let(:admin) { create(:user).tap { |user| user.add_role(:admin) } }
  let(:account) { create(:user) }

  describe 'PATCH /api/v1/admin/accounts/:id/plan' do
    it 'lets an admin switch another account to the pro plan' do
      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['id']).to eq(account.id)
      expect(body['plan']).to eq(User::PRO_PLAN)
      expect(body['project_limit']).to eq(10)
      expect(account.reload.plan).to eq(User::PRO_PLAN)
    end

    it 'applies the new limits to the projects the account owns' do
      project = create(:project, :with_owner, owner: account)

      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(admin), as: :json

      expect(project.reload.plan).to eq(User::PRO_PLAN)
      expect(Plans::Entitlements.endpoint_limit(account.reload)).to eq(50)
    end

    it 'rejects an unknown plan' do
      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { account: { plan: 'enterprise' } }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'returns not found for an unknown account' do
      patch "/api/v1/admin/accounts/#{SecureRandom.uuid}/plan",
            params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'forbids a non admin account' do
      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(account), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'forbids a project owner without the global admin role' do
      project_owner = create(:user)
      create(:project, :with_owner, owner: project_owner)

      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(project_owner), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'forbids a maintainer of the target account project' do
      project = create(:project, :with_owner, owner: account)
      maintainer = create(:user)
      create(:project_membership, project: project, user: maintainer, role: :maintainer)

      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(maintainer), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'forbids an outsider with no project relationship' do
      outsider = create(:user)

      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { account: { plan: User::PRO_PLAN } }, headers: auth_headers(outsider), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'requires authentication' do
      patch "/api/v1/admin/accounts/#{account.id}/plan", params: { account: { plan: User::PRO_PLAN } }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end
  end
end
