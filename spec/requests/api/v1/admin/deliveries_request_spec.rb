require 'swagger_helper'

describe 'Admin::Deliveries', type: :request do
  let(:admin) { create(:user).tap { |user| user.add_role(:admin) } }
  let(:outsider) { create(:user) }
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  def create_delivery(created_at: Time.current, **attributes)
    create(:message, project: project, endpoint: endpoint, created_at: created_at, **attributes)
  end

  describe 'GET /api/v1/admin/deliveries' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/admin/deliveries'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the requester is not a system administrator' do
      it 'denies access' do
        get '/api/v1/admin/deliveries', headers: auth_headers(outsider)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'when the requester is a system administrator' do
      it 'serializes delivery state and failure category without evidence' do
        message = create_delivery(status: :failed, attempt_count: 1)
        create(:delivery_attempt, message: message, attempt_number: 1, response_status: 503,
                                  request_body: '{"card_number":"4242424242424242"}',
                                  response_body: '{"token":"leaked-response-token"}')

        get '/api/v1/admin/deliveries', headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        entry = json_response['data'].find { |item| item['id'] == message.id }
        expect(entry).to include(
          'status' => 'failed',
          'delivery_state' => 'terminal',
          'failure_category' => Webhooks::FailureCategory::HTTP_ERROR,
          'last_response_status' => 503,
          'webhook_id' => message.webhook_id,
          'endpoint' => { 'id' => endpoint.id, 'name' => endpoint.name },
          'project' => { 'id' => project.id, 'name' => project.name }
        )
        expect(entry['event']).to include('id' => message.event_id, 'event_type' => message.event.event_type)

        expect(entry.keys).to contain_exactly(
          'id', 'status', 'attempt_count', 'terminal_at', 'next_retry_at', 'last_attempt_at', 'last_response_status',
          'last_duration_ms', 'created_at', 'updated_at', 'webhook_id', 'delivery_state', 'failure_category', 'hold',
          'event', 'endpoint', 'project'
        )
        expect(response.body).not_to include('4242424242424242', 'leaked-response-token')
      end

      it 'filters deliveries by status' do
        failed = create_delivery(status: :failed)
        create_delivery(status: :succeeded)

        get '/api/v1/admin/deliveries', params: { status: 'failed' }, headers: auth_headers(admin)

        expect(json_response['data'].map { |item| item['id'] }).to eq([failed.id])
      end

      it 'never reports a failure category for a successful delivery' do
        message = create_delivery(status: :succeeded)
        create(:delivery_attempt, message: message, attempt_number: 1, response_status: 202)

        get '/api/v1/admin/deliveries', headers: auth_headers(admin)

        entry = json_response['data'].find { |item| item['id'] == message.id }
        expect(entry).to include('status' => 'succeeded', 'failure_category' => nil, 'last_response_status' => 202)
      end

      it 'filters deliveries by failure category' do
        timeout = create_delivery
        create(:delivery_attempt, message: timeout, attempt_number: 1, error_type: 'Net::ReadTimeout')
        create_delivery.tap do |message|
          create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500)
        end

        get '/api/v1/admin/deliveries', params: { failure_category: Webhooks::FailureCategory::TIMEOUT },
                                       headers: auth_headers(admin)

        expect(json_response['data'].map { |item| item['id'] }).to eq([timeout.id])
      end

      it 'excludes deliveries older than the default window' do
        recent = create_delivery(created_at: 1.day.ago)
        create_delivery(created_at: 10.days.ago)

        get '/api/v1/admin/deliveries', headers: auth_headers(admin)

        expect(json_response['data'].map { |item| item['id'] }).to eq([recent.id])
      end

      it 'lists the newest deliveries first' do
        older = create_delivery(created_at: 2.days.ago)
        newer = create_delivery(created_at: 1.hour.ago)

        get '/api/v1/admin/deliveries', headers: auth_headers(admin)

        expect(json_response['data'].map { |item| item['id'] }).to eq([newer.id, older.id])
      end

      it 'loads deliveries without an extra query per row' do
        create_delivery
        get '/api/v1/admin/deliveries', headers: auth_headers(admin)

        baseline = sql_queries { get '/api/v1/admin/deliveries', headers: auth_headers(admin) }.size

        create_list(:message, 2, project: project, endpoint: endpoint)

        expect(sql_queries { get '/api/v1/admin/deliveries', headers: auth_headers(admin) }.size).to eq(baseline)
      end

      it 'filters deliveries by billing owner account without including joined-member projects' do
        owner = create(:user)
        owned_project = create(:project, billing_owner: owner)
        owned_endpoint = create(:endpoint, project: owned_project)
        owned_message = create(:message, project: owned_project, endpoint: owned_endpoint)

        joined_project = create(:project, billing_owner: create(:user))
        create(:project_membership, project: joined_project, user: owner, role: :maintainer)
        joined_endpoint = create(:endpoint, project: joined_project)
        create(:message, project: joined_project, endpoint: joined_endpoint)

        get '/api/v1/admin/deliveries', params: { account_id: owner.id }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to contain_exactly(owned_message.id)
      end

      it 'caps the requested page size' do
        get '/api/v1/admin/deliveries', params: { page: { size: 500 } }, headers: auth_headers(admin)

        expect(json_response['meta']['page_size']).to eq(Pagination::MAX_PAGE_SIZE)
      end
    end
  end
end
