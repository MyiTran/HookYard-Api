require 'swagger_helper'

describe 'Admin::Accounts', type: :request do
  let(:admin) { create(:user).tap { |user| user.add_role(:admin) } }
  let(:account) { create(:user) }

  describe 'PATCH /api/v1/admin/accounts/:id/plan' do
    it 'lets a free-plan system admin upgrade an account from free to pro' do
      admin.update!(plan: User::FREE_PLAN)

      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { plan: User::PRO_PLAN }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['id']).to eq(account.id)
      expect(body['email']).to eq(account.email)
      expect(body['name']).to eq(account.name)
      expect(body['plan']).to eq(User::PRO_PLAN)
      expect(body['roles']).to eq([])
      expect(body['confirmed']).to be(true)
      expect(account.reload.plan).to eq(User::PRO_PLAN)
    end

    it 'lets an admin downgrade an account from pro to free' do
      account.update!(plan: User::PRO_PLAN)

      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { plan: User::FREE_PLAN }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['plan']).to eq(User::FREE_PLAN)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'does not mutate project, membership, usage, endpoint, message, or delivery records' do
      project = create(:project, :with_owner, owner: account)
      endpoint = create(:endpoint, project: project)
      message = create(:message, project: project, endpoint: endpoint)
      attempt = create(:delivery_attempt, message: message)
      usage = UserUsagePeriod.create!(
        user: account,
        period_starts_on: UserUsagePeriod.period_start_for(Time.current),
        deliveries_count: 3
      )

      project_snapshot = project.attributes
      membership_snapshot = project.project_memberships.first.attributes
      usage_snapshot = usage.attributes
      endpoint_snapshot = endpoint.attributes
      message_snapshot = message.attributes
      attempt_snapshot = attempt.attributes

      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { plan: User::PRO_PLAN }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:ok)
      expect(project.reload.attributes).to eq(project_snapshot)
      expect(project.project_memberships.first.attributes).to eq(membership_snapshot)
      expect(usage.reload.attributes).to eq(usage_snapshot)
      expect(endpoint.reload.attributes).to eq(endpoint_snapshot)
      expect(message.reload.attributes).to eq(message_snapshot)
      expect(attempt.reload.attributes).to eq(attempt_snapshot)
    end

    it 'rejects an invalid plan without mutating the account' do
      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { plan: 'enterprise' }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end

    it 'returns not found for an unknown account' do
      patch "/api/v1/admin/accounts/#{SecureRandom.uuid}/plan",
            params: { plan: User::PRO_PLAN }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'rejects changing an admin account as a customer plan target' do
      target_admin = create(:user).tap { |user| user.add_role(:admin) }

      patch "/api/v1/admin/accounts/#{target_admin.id}/plan",
            params: { plan: User::PRO_PLAN }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(target_admin.reload.plan).to eq(User::FREE_PLAN)
      expect(target_admin).to be_admin
    end

    it 'rejects changing the current admin account as a customer plan target' do
      patch "/api/v1/admin/accounts/#{admin.id}/plan",
            params: { plan: User::PRO_PLAN }, headers: auth_headers(admin), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(admin.reload.plan).to eq(User::FREE_PLAN)
      expect(admin).to be_admin
    end

    it 'forbids a non-admin account' do
      patch "/api/v1/admin/accounts/#{account.id}/plan",
            params: { plan: User::PRO_PLAN }, headers: auth_headers(account), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(account.reload.plan).to eq(User::FREE_PLAN)
    end
  end

  describe 'GET /api/v1/admin/accounts/:id' do
    let!(:owned_project) { create(:project, billing_owner: account, name: 'Owned Project') }
    let!(:joined_project) do
      create(:project, name: 'Joined Project').tap do |project|
        create(:project_membership, project: project, user: account, role: :maintainer)
      end
    end

    context 'when unauthenticated' do
      it 'requires authentication' do
        get "/api/v1/admin/accounts/#{account.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the requester is not a system administrator' do
      it 'denies access' do
        get "/api/v1/admin/accounts/#{account.id}", headers: auth_headers(account)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'when the requester is a system administrator' do
      it 'returns safe account metadata and only projects owned by the account' do
        get "/api/v1/admin/accounts/#{account.id}", headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body).to include(
          'id' => account.id,
          'email' => account.email,
          'name' => account.name,
          'plan' => User::FREE_PLAN,
          'owned_project_count' => 1
        )
        expect(body['owned_projects']).to contain_exactly(
          { 'id' => owned_project.id, 'name' => owned_project.name }
        )
        expect(body['owned_projects']).not_to include(
          { 'id' => joined_project.id, 'name' => joined_project.name }
        )
        expect(body.keys).to contain_exactly(
          'id', 'email', 'first_name', 'last_name', 'name', 'plan', 'roles', 'confirmed', 'sign_in_count',
          'last_sign_in_at', 'created_at', 'owned_project_count', 'owned_projects'
        )
        expect(response.body).not_to include(
          'encrypted_password', 'reset_password_token', 'confirmation_token', 'jti', 'signing_secret'
        )
      end

      it 'returns not found for an unknown account' do
        get "/api/v1/admin/accounts/#{SecureRandom.uuid}", headers: auth_headers(admin)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
