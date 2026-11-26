require 'swagger_helper'

describe 'Dashboards', type: :request do
  let(:user) { create(:user, :pro) }
  let!(:owned_project) { create(:project, :with_owner, owner: user, name: 'Owned Project') }
  let!(:shared_project) do
    create(:project, name: 'Shared Project').tap do |project|
      create(:project_membership, project: project, user: user, role: :maintainer)
    end
  end
  let!(:foreign_project) { create(:project, name: 'Foreign Project') }

  let!(:owned_endpoint) { create(:endpoint, project: owned_project) }

  before do
    owned_endpoint.update_columns(circuit_state: 'circuit_open', queued_message_count: 2)

    create(:delivery_metric, project: owned_project, day: Date.current,
                             attempts_count: 10, successes_count: 8, failures_count: 2)
    create(:delivery_metric, project: shared_project, day: Date.current,
                             attempts_count: 5, successes_count: 4, failures_count: 1)
    create(:delivery_metric, project: foreign_project, day: Date.current,
                             attempts_count: 99, successes_count: 98, failures_count: 1)

    held_message = create(:message, project: owned_project, endpoint: owned_endpoint)
    held_message.hold!(reason: 'endpoint_circuit_open')
    create(:message, project: owned_project, endpoint: owned_endpoint, status: :delivering)
    create(:message, project: owned_project, endpoint: owned_endpoint)
    create(:message, project: owned_project, endpoint: owned_endpoint, next_retry_at: 1.minute.ago)
  end

  describe 'GET /api/v1/dashboard' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/dashboard'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated' do
      it 'returns only workspace projects and scoped health aggregates' do
        get '/api/v1/dashboard', headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        body = json_response

        expect(body['workspace']).to eq(
          'project_count' => 2,
          'owned_project_count' => 1,
          'shared_project_count' => 1
        )
        expect(body['delivery_health']).to include(
          'period_label' => 'Last 7 days',
          'total' => 15,
          'succeeded' => 12,
          'failed' => 3,
          'in_flight' => 3,
          'held' => 1,
          'retries_due' => 1,
          'success_rate' => 80.0
        )
        expect(body['needs_attention']).to eq(
          'open_circuit_endpoints' => 1,
          'held_deliveries' => 1,
          'retries_due' => 1,
          'failed_deliveries' => 3
        )
      end

      it 'returns owned and shared project cards without leaking foreign projects' do
        get '/api/v1/dashboard', headers: auth_headers(user)

        body = json_response
        project_ids = body['projects'].map { |project| project['id'] }

        expect(project_ids).to contain_exactly(owned_project.id, shared_project.id)
        expect(project_ids).not_to include(foreign_project.id)

        owned_entry = body['projects'].find { |project| project['id'] == owned_project.id }
        shared_entry = body['projects'].find { |project| project['id'] == shared_project.id }

        expect(owned_entry).to include(
          'relationship' => 'owned',
          'current_user_role' => 'owner',
          'effective_plan' => User::PRO_PLAN
        )
        expect(shared_entry).to include(
          'relationship' => 'shared',
          'current_user_role' => 'maintainer',
          'effective_plan' => User::FREE_PLAN
        )
      end

      it 'prioritizes projects needing attention and bounds the project list' do
        get '/api/v1/dashboard', headers: auth_headers(user)

        projects = json_response['projects']
        expect(projects.size).to be <= 5
        expect(projects.first['id']).to eq(owned_project.id)
      end

      it 'does not expose delivery evidence or credentials' do
        endpoint = create(:endpoint, project: owned_project, url: 'https://example.test/hook?token=secret')
        endpoint.update_columns(url: 'https://example.test/hook?token=secret')

        get '/api/v1/dashboard', headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include(
          'secret', 'signing_secret', 'request_body', 'response_body', 'request_headers', 'response_headers',
          'payload', 'token_digest'
        )
      end

      it 'returns the empty dashboard contract for a user without projects' do
        empty_user = create(:user).tap { |account| account.add_role(:support) }

        get '/api/v1/dashboard', headers: auth_headers(empty_user)

        expect(response).to have_http_status(:ok)
        expect(json_response).to eq(
          'workspace' => {
            'project_count' => 0,
            'owned_project_count' => 0,
            'shared_project_count' => 0
          },
          'delivery_health' => {
            'period_label' => 'Last 7 days',
            'total' => 0,
            'succeeded' => 0,
            'failed' => 0,
            'in_flight' => 0,
            'held' => 0,
            'retries_due' => 0,
            'success_rate' => 0.0
          },
          'needs_attention' => {
            'open_circuit_endpoints' => 0,
            'held_deliveries' => 0,
            'retries_due' => 0,
            'failed_deliveries' => 0
          },
          'projects' => []
        )
      end

      it 'returns zero metrics for an accessible project without delivery data' do
        user_without_delivery_data = create(:user)
        create(:project, :with_owner, owner: user_without_delivery_data)

        get '/api/v1/dashboard', headers: auth_headers(user_without_delivery_data)

        expect(response).to have_http_status(:ok)
        expect(json_response['workspace']['project_count']).to eq(1)
        expect(json_response['delivery_health']).to include(
          'total' => 0,
          'succeeded' => 0,
          'failed' => 0,
          'success_rate' => 0.0
        )
        expect(json_response['projects']).to have_attributes(size: 1)
      end

      it 'keeps dashboard access available to support and admin users' do
        support_user = create(:user).tap { |account| account.add_role(:support) }
        admin_user = create(:user).tap { |account| account.add_role(:admin) }

        [support_user, admin_user].each do |account|
          get '/api/v1/dashboard', headers: auth_headers(account)

          expect(response).to have_http_status(:ok)
        end
      end
    end
  end
end
