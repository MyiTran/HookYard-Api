require 'swagger_helper'

describe 'Admin::Endpoints', type: :request do
  let(:admin) { create(:user).tap { |user| user.add_role(:admin) } }
  let(:outsider) { create(:user) }
  let(:project) { create(:project) }
  let!(:endpoint) { create(:endpoint, project: project) }
  let!(:open_endpoint) { create(:endpoint, project: project) }

  before { open_endpoint.update_columns(circuit_state: 'circuit_open', queued_message_count: 2) }

  describe 'GET /api/v1/admin/endpoints' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/admin/endpoints'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the requester is not a system administrator' do
      it 'denies access' do
        get '/api/v1/admin/endpoints', headers: auth_headers(outsider)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'when the requester is a system administrator' do
      it 'returns endpoints with project, circuit and queue state' do
        get '/api/v1/admin/endpoints', headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        entry = json_response['data'].find { |item| item['id'] == open_endpoint.id }
        expect(entry).to include(
          'circuit_state' => 'circuit_open',
          'queued_message_count' => 2,
          'project' => { 'id' => project.id, 'name' => project.name }
        )
        expect(entry.keys).to contain_exactly(
          'id', 'name', 'url', 'active', 'archived_at', 'event_types', 'circuit_state', 'circuit_opened_at',
          'queued_message_count', 'created_at', 'updated_at', 'project'
        )
      end

      it 'redacts secrets embedded in the endpoint url' do
        endpoint.update_columns(url: 'https://demo.example.test/hooks?access_token=super-secret-token')

        get '/api/v1/admin/endpoints', headers: auth_headers(admin)

        entry = json_response['data'].find { |item| item['id'] == endpoint.id }
        expect(entry['url']).to eq("https://demo.example.test/hooks?access_token=#{Webhooks::EvidenceSanitizer::REDACTED_VALUE}")
        expect(response.body).not_to include('super-secret-token')
      end

      it 'filters endpoints by circuit state' do
        get '/api/v1/admin/endpoints', params: { circuit_state: 'circuit_open' }, headers: auth_headers(admin)

        expect(json_response['data'].map { |item| item['id'] }).to eq([open_endpoint.id])
      end

      it 'filters endpoints by project' do
        other_endpoint = create(:endpoint, project: create(:project))

        get '/api/v1/admin/endpoints', params: { project_id: project.id }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to contain_exactly(endpoint.id, open_endpoint.id)
        expect(ids).not_to include(other_endpoint.id)
      end

      it 'loads endpoint projects without an extra query per endpoint' do
        get '/api/v1/admin/endpoints', headers: auth_headers(admin)

        baseline = sql_queries { get '/api/v1/admin/endpoints', headers: auth_headers(admin) }.size

        create_list(:endpoint, 2, project: project)

        expect(sql_queries { get '/api/v1/admin/endpoints', headers: auth_headers(admin) }.size).to eq(baseline)
      end

      it 'caps the requested page size' do
        get '/api/v1/admin/endpoints', params: { page: { size: 500 } }, headers: auth_headers(admin)

        expect(json_response['meta']['page_size']).to eq(Pagination::MAX_PAGE_SIZE)
      end
    end
  end

  describe 'GET /api/v1/admin/endpoints/:id' do
    before do
      create(:message, project: project, endpoint: endpoint)
      create(:message, project: project, endpoint: endpoint).tap do |message|
        message.hold!(reason: 'endpoint_circuit_open')
      end

      endpoint.update_columns(
        url: 'https://demo.example.test/hooks?access_token=super-secret-token',
        circuit_state: 'circuit_open',
        queued_message_count: 2
      )
    end

    context 'when unauthenticated' do
      it 'requires authentication' do
        get "/api/v1/admin/endpoints/#{endpoint.id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the requester is not a system administrator' do
      it 'denies access' do
        get "/api/v1/admin/endpoints/#{endpoint.id}", headers: auth_headers(outsider)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'when the requester is a system administrator' do
      it 'returns safe endpoint metadata, account summary and delivery summary' do
        get "/api/v1/admin/endpoints/#{endpoint.id}", headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        body = json_response
        expect(body).to include(
          'id' => endpoint.id,
          'name' => endpoint.name,
          'paused' => false,
          'circuit_state' => 'circuit_open',
          'queued_message_count' => 2,
          'project' => { 'id' => project.id, 'name' => project.name },
          'account' => {
            'id' => project.billing_owner_id,
            'email' => project.billing_owner.email,
            'plan' => project.billing_owner.plan
          }
        )
        expect(body['url']).to eq(
          "https://demo.example.test/hooks?access_token=#{Webhooks::EvidenceSanitizer::REDACTED_VALUE}"
        )
        expect(body['delivery_summary']).to include(
          'total' => 2,
          'recent' => 2,
          'held' => 1
        )
        expect(body.keys).to contain_exactly(
          'id', 'name', 'url', 'active', 'archived_at', 'event_types', 'circuit_state', 'circuit_opened_at',
          'queued_message_count', 'created_at', 'updated_at', 'project', 'paused', 'account', 'delivery_summary'
        )
        expect(response.body).not_to include('super-secret-token', 'signing_secret', 'request_headers', 'request_body',
                                             'response_body')
      end

      it 'returns not found for an unknown endpoint' do
        get "/api/v1/admin/endpoints/#{SecureRandom.uuid}", headers: auth_headers(admin)

        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
