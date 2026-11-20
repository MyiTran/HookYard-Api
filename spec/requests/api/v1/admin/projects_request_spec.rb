require 'swagger_helper'

describe 'Admin::Projects', type: :request do
  let(:admin) { create(:user).tap { |user| user.add_role(:admin) } }
  let(:outsider) { create(:user) }
  let!(:pro_project) { create(:project, :pro, name: 'Pro Demo Project') }
  let!(:free_project) { create(:project, name: 'Free Demo Project') }

  describe 'GET /api/v1/admin/projects' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/admin/projects'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the requester is not a system administrator' do
      it 'denies access' do
        get '/api/v1/admin/projects', headers: auth_headers(outsider)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'when the requester is a system administrator' do
      it 'returns projects with their billing owner and inherited plan' do
        get '/api/v1/admin/projects', headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        entry = json_response['data'].find { |item| item['id'] == pro_project.id }
        expect(entry).to include(
          'name' => 'Pro Demo Project',
          'plan' => User::PRO_PLAN,
          'account' => {
            'id' => pro_project.billing_owner_id,
            'email' => pro_project.billing_owner.email,
            'plan' => User::PRO_PLAN
          }
        )
      end

      it 'does not allow changing the plan on the project endpoint' do
        patch "/api/v1/admin/projects/#{free_project.id}/plan",
              params: { plan: User::PRO_PLAN }, headers: auth_headers(admin), as: :json

        expect(response).to have_http_status(:not_found)
        expect(free_project.reload.plan).to eq(User::FREE_PLAN)
      end

      it 'searches projects by name' do
        get '/api/v1/admin/projects', params: { q: 'Free Demo' }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to include(free_project.id)
        expect(ids).not_to include(pro_project.id)
      end

      it 'loads billing owners without an extra query per project' do
        get '/api/v1/admin/projects', headers: auth_headers(admin)

        baseline = sql_queries { get '/api/v1/admin/projects', headers: auth_headers(admin) }.size

        create_list(:project, 2)

        expect(sql_queries { get '/api/v1/admin/projects', headers: auth_headers(admin) }.size).to eq(baseline)
      end

      it 'filters projects by billing owner account' do
        get '/api/v1/admin/projects', params: { account_id: pro_project.billing_owner_id }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to contain_exactly(pro_project.id)
        expect(ids).not_to include(free_project.id)
      end

      it 'filters projects by the effective billing owner plan' do
        get '/api/v1/admin/projects', params: { plan: User::PRO_PLAN }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to contain_exactly(pro_project.id)
        expect(ids).not_to include(free_project.id)
      end

      it 'caps the requested page size' do
        get '/api/v1/admin/projects', params: { page: { size: 500 } }, headers: auth_headers(admin)

        expect(json_response['meta']['page_size']).to eq(Pagination::MAX_PAGE_SIZE)
      end
    end
  end

  describe 'GET /api/v1/admin/projects/:id' do
    let!(:active_endpoint) { create(:endpoint, project: pro_project) }

    before do
      create(:project_membership, project: pro_project, role: :maintainer)
      create(:endpoint, project: pro_project, active: false)
      create(:endpoint, project: pro_project, archived_at: Time.current)
      active_endpoint.update_columns(circuit_state: 'circuit_open', queued_message_count: 2)
    end

    context 'when unauthenticated' do
      it 'requires authentication' do
        get "/api/v1/admin/projects/#{pro_project.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the requester is not a system administrator' do
      it 'denies access' do
        get "/api/v1/admin/projects/#{pro_project.id}", headers: auth_headers(outsider)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'when the requester is a system administrator' do
      it 'returns project metadata, billing owner, member count and endpoint health summary' do
        get "/api/v1/admin/projects/#{pro_project.id}", headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body).to include(
          'id' => pro_project.id,
          'name' => pro_project.name,
          'plan' => User::PRO_PLAN,
          'member_count' => 1,
          'account' => {
            'id' => pro_project.billing_owner_id,
            'email' => pro_project.billing_owner.email,
            'plan' => User::PRO_PLAN
          }
        )
        expect(body['endpoint_summary']).to include(
          'total' => 3,
          'active' => 2,
          'paused' => 1,
          'archived' => 1,
          'enabled' => 2,
          'circuit_open' => 1,
          'disabled' => 0,
          'queued_messages' => 2
        )
        expect(body.keys).to contain_exactly(
          'id', 'name', 'created_at', 'updated_at', 'plan', 'account', 'member_count', 'endpoint_summary'
        )
        expect(response.body).not_to include('signing_secret', 'request_body', 'response_body', 'token_digest')
      end

      it 'returns not found for an unknown project' do
        get "/api/v1/admin/projects/#{SecureRandom.uuid}", headers: auth_headers(admin)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
