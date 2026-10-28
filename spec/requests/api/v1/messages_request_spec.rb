require 'swagger_helper'

describe 'Messages', type: :request do
  let(:user) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: user) }
  let(:endpoint) { create(:endpoint, project: project, event_types: ['order.created']) }
  let(:event) { create(:event, project: project, event_type: 'order.created', payload: { 'order_id' => 'ord_1' }) }

  def create_message(project:, endpoint:, event_type: 'order.created', status: :pending, created_at: Time.current)
    message_event = create(:event, project: project, event_type: event_type)
    create(:message, event: message_event, endpoint: endpoint, status: status, created_at: created_at)
  end

  def payload_query_count
    queries = []
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      next if payload[:cached]

      sql = payload[:sql]
      if sql.match?(/FROM "messages"|FROM "delivery_attempts"|FROM "events"|FROM "endpoints"|FROM "projects"/)
        queries << sql
      end
    end

    yield
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  describe 'GET /api/v1/messages' do
    it 'only lists messages from projects the user can access' do
      visible = create(:message, event: event, endpoint: endpoint)
      create(:message)

      get '/api/v1/messages', headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([visible.id])
    end

    it 'does not let a foreign project filter bypass the policy scope' do
      create(:message)
      other_project = create(:project)

      get '/api/v1/messages', params: { project_id: other_project.id }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to be_empty
    end

    it 'returns message, project and endpoint summaries' do
      message = create(:message, event: event, endpoint: endpoint, status: :succeeded)

      get '/api/v1/messages', headers: auth_headers(user)

      entry = JSON.parse(response.body)['data'].first
      expect(entry['id']).to eq(message.id)
      expect(entry['webhook_id']).to eq(message.webhook_id)
      expect(entry['status']).to eq('succeeded')
      expect(entry['event_id']).to eq(event.id)
      expect(entry['event_type']).to eq('order.created')
      expect(entry['project']).to eq('id' => project.id, 'name' => project.name)
      expect(entry['endpoint']).to eq('id' => endpoint.id, 'name' => endpoint.name, 'url' => endpoint.url)
    end

    it 'lists the newest messages first' do
      older = create_message(project: project, endpoint: endpoint, created_at: 2.hours.ago)
      newer = create_message(project: project, endpoint: endpoint, created_at: 1.hour.ago)

      get '/api/v1/messages', headers: auth_headers(user)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([newer.id, older.id])
    end

    it 'paginates with the shared metadata' do
      3.times { create_message(project: project, endpoint: endpoint) }

      get '/api/v1/messages', params: { page: { number: 2, size: 2 } }, headers: auth_headers(user)

      body = JSON.parse(response.body)
      expect(body['data'].size).to eq(1)
      expect(body['meta']).to include(
        'page_number' => 2,
        'page_size' => 2,
        'total_count' => 3,
        'last_page' => 2
      )
    end

    it 'returns the persisted attempt count and the latest attempt fields' do
      message = create(:message, event: event, endpoint: endpoint)
      message.update_columns(attempt_count: 2)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500, duration_ms: 30)
      latest = create(:delivery_attempt, message: message, attempt_number: 2, response_status: 200, duration_ms: 12)

      get '/api/v1/messages', headers: auth_headers(user)

      entry = JSON.parse(response.body)['data'].first
      expect(entry['attempt_count']).to eq(2)
      expect(entry['last_response_status']).to eq(200)
      expect(entry['last_duration_ms']).to eq(12)
      expect(entry['last_error_type']).to be_nil
      expect(Time.zone.parse(entry['last_attempt_at'])).to be_within(1.second).of(latest.created_at)
    end

    it 'returns nil summary fields for a message without attempts' do
      create(:message, event: event, endpoint: endpoint)

      get '/api/v1/messages', headers: auth_headers(user)

      entry = JSON.parse(response.body)['data'].first
      expect(entry['attempt_count']).to eq(0)
      expect(entry['last_attempt_at']).to be_nil
      expect(entry['last_response_status']).to be_nil
      expect(entry['last_duration_ms']).to be_nil
      expect(entry['last_error_type']).to be_nil
    end

    it 'serializes the retry lifecycle contract' do
      message = create(:message, event: event, endpoint: endpoint)
      message.update_columns(attempt_count: 2, next_retry_at: 5.minutes.from_now)

      get '/api/v1/messages', headers: auth_headers(user)

      entry = JSON.parse(response.body)['data'].first
      expect(entry).to include(
        'attempt_count' => 2,
        'max_attempts' => 8,
        'retryable' => true
      )
      expect(entry['next_retry_at']).to be_present
      expect(entry['terminal_at']).to be_nil
      expect(entry.keys).not_to include('delivery_lease_expires_at')
    end

    describe 'filters' do
      it 'searches by message id' do
        message = create(:message, event: event, endpoint: endpoint)
        create(:message)

        get '/api/v1/messages', params: { q: message.id[0, 8] }, headers: auth_headers(user)

        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([message.id])
      end

      it 'searches by webhook id' do
        message = create(:message, event: event, endpoint: endpoint)

        get '/api/v1/messages', params: { q: "msg_#{message.id}" }, headers: auth_headers(user)

        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([message.id])
      end

      it 'searches by delivery attempt request id without duplicates' do
        message = create(:message, event: event, endpoint: endpoint)
        create(:delivery_attempt, message: message, attempt_number: 1, request_id: 'req_SUPPORT123')
        create(:delivery_attempt, message: message, attempt_number: 2, request_id: 'req_SUPPORT456')

        get '/api/v1/messages', params: { q: 'support123' }, headers: auth_headers(user)

        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([message.id])
      end

      it 'filters by project, endpoint, status and event type together' do
        other_endpoint = create(:endpoint, project: project)
        visible = create(:message, event: event, endpoint: endpoint, status: :failed)
        create(:message, event: event, endpoint: other_endpoint, status: :failed)
        create(:message, event: create(:event, project: project, event_type: 'payment.failed'),
                         endpoint: endpoint, status: :failed)
        create(:message, event: create(:event, project: project, event_type: 'order.created'),
                         endpoint: endpoint, status: :succeeded)

        get '/api/v1/messages',
            params: { project_id: project.id, endpoint_id: endpoint.id, status: 'failed', event_type: 'order.created' },
            headers: auth_headers(user)

        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([visible.id])
      end

      it 'filters by creation date range' do
        old_message = create_message(project: project, endpoint: endpoint, created_at: 3.days.ago)
        recent_message = create_message(project: project, endpoint: endpoint, created_at: 1.hour.ago)

        get '/api/v1/messages', params: { from: 1.day.ago.iso8601 }, headers: auth_headers(user)
        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([recent_message.id])

        get '/api/v1/messages', params: { to: 1.day.ago.iso8601 }, headers: auth_headers(user)
        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([old_message.id])
      end

      it 'orders the oldest messages first when requested' do
        older = create_message(project: project, endpoint: endpoint, created_at: 2.hours.ago)
        newer = create_message(project: project, endpoint: endpoint, created_at: 1.hour.ago)

        get '/api/v1/messages', params: { order: 'created_asc' }, headers: auth_headers(user)

        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([older.id, newer.id])
      end

      it 'falls back to the default order for an unsupported order value' do
        older = create_message(project: project, endpoint: endpoint, created_at: 2.hours.ago)
        newer = create_message(project: project, endpoint: endpoint, created_at: 1.hour.ago)

        get '/api/v1/messages', params: { order: 'messages.id; DROP TABLE messages' }, headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([newer.id, older.id])
      end
    end

    it 'never exposes secrets, signature headers or attempt evidence' do
      message = create(:message, event: event, endpoint: endpoint)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 200,
                                request_headers: { 'webhook-signature' => 'v1,top-secret-signature' })

      get '/api/v1/messages', headers: auth_headers(user)

      entry = JSON.parse(response.body)['data'].first
      expect(response.body).not_to include(endpoint.current_signing_secret.secret)
      expect(response.body).not_to include('v1,top-secret-signature')
      expect(response.body).not_to include('token_digest')
      expect(entry).not_to have_key('attempts')
      expect(entry).not_to have_key('request_body')
      expect(entry).not_to have_key('response_body')
    end

    it 'keeps the number of payload queries bounded' do
      3.times do |index|
        message = create_message(project: project, endpoint: endpoint, created_at: index.hours.ago)
        create(:delivery_attempt, message: message, attempt_number: 1, response_status: 200)
      end

      query_count = payload_query_count do
        get '/api/v1/messages', headers: auth_headers(user)
      end

      expect(response).to have_http_status(:ok)
      expect(query_count).to be <= 6
    end

    context 'when the user is not authenticated' do
      it 'returns unauthorized' do
        get '/api/v1/messages'

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe 'GET /api/v1/projects/:project_id/messages/:id' do
    context 'when the message belongs to the project' do
      it 'returns the delivery lifecycle fields and attempts' do
        message = create(:message, event: event, endpoint: endpoint)
        create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500)
        message.update_columns(attempt_count: 1)

        get "/api/v1/projects/#{project.id}/messages/#{message.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(json_response['id']).to eq(message.id)
        expect(json_response).to include(
          'attempt_count' => 1,
          'max_attempts' => 8,
          'status' => 'pending',
          'retryable' => true
        )
        expect(json_response['attempts'].first['status']).to eq('failed')
        expect(json_response.keys).not_to include('delivery_lease_expires_at')
      end

      it 'exposes the terminal timestamp for a delivered message' do
        message = create(:message, event: event, endpoint: endpoint)
        message.update_columns(status: 'succeeded', attempt_count: 1, terminal_at: Time.current)

        get "/api/v1/projects/#{project.id}/messages/#{message.id}", headers: auth_headers(user)

        expect(json_response['status']).to eq('succeeded')
        expect(json_response['terminal_at']).to be_present
        expect(json_response['retryable']).to be(false)
      end
    end

    context 'when the message belongs to another project' do
      it 'is not found' do
        other_message = create(:message)

        get "/api/v1/projects/#{project.id}/messages/#{other_message.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET /api/v1/projects/:project_id/endpoints/:endpoint_id/messages' do
    it 'lists the endpoint messages with the retry lifecycle fields' do
      message = create(:message, event: event, endpoint: endpoint)
      message.update_columns(attempt_count: 1, next_retry_at: 1.minute.from_now)

      get "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/messages", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(message.id)
      expect(json_response['data'].first).to include(
        'attempt_count' => 1,
        'max_attempts' => 8
      )
    end
  end
end
