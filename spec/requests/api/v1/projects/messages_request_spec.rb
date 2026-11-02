require 'swagger_helper'

describe 'Projects::Messages', type: :request do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project, event_types: ['order.created']) }
  let(:event) { create(:event, project: project, event_type: 'order.created', payload: { 'order_id' => 'ord_1' }) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  def endpoint_messages_path(project_id, endpoint_id)
    "/api/v1/projects/#{project_id}/endpoints/#{endpoint_id}/messages"
  end

  def message_path(project_id, message_id)
    "/api/v1/projects/#{project_id}/messages/#{message_id}"
  end

  def payload_query_count
    queries = []
    subscription = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      next if payload[:cached]

      sql = payload[:sql]
      queries << sql if sql.match?(/FROM "messages"|FROM "delivery_attempts"|FROM "events"/)
    end

    yield
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  describe 'GET /api/v1/projects/:project_id/endpoints/:endpoint_id/messages' do
    it 'lets a member list the messages of an endpoint' do
      message = create(:message, event: event, endpoint: endpoint)

      get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      entry = JSON.parse(response.body)['data'].first
      expect(entry['id']).to eq(message.id)
      expect(entry['webhook_id']).to eq("msg_#{message.id}")
      expect(entry['status']).to eq('pending')
      expect(entry['event_id']).to eq(event.id)
      expect(entry['event_type']).to eq('order.created')
    end

    it 'lists the newest messages first' do
      older = create(:message, event: event, endpoint: endpoint, created_at: 2.hours.ago)
      newer = create(:message, event: create(:event, project: project), endpoint: endpoint, created_at: 1.hour.ago)

      get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(maintainer)

      ids = JSON.parse(response.body)['data'].map { |entry| entry['id'] }
      expect(ids).to eq([newer.id, older.id])
    end

    it 'paginates with the shared pagination metadata' do
      3.times { create(:message, event: create(:event, project: project), endpoint: endpoint) }

      get endpoint_messages_path(project.id, endpoint.id),
          params: { page: { number: 2, size: 2 } }, headers: auth_headers(maintainer)

      body = JSON.parse(response.body)
      expect(body['data'].size).to eq(1)
      expect(body['meta']).to include(
        'page_number' => 2,
        'page_size' => 2,
        'total_count' => 3,
        'last_page' => 2
      )
    end

    it 'summarizes attempts of each message' do
      message = create(:message, event: event, endpoint: endpoint)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500, duration_ms: 30)
      latest = create(:delivery_attempt, message: message, attempt_number: 2, response_status: 200, duration_ms: 12)
      message.update_columns(attempt_count: 2)

      get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(maintainer)

      entry = JSON.parse(response.body)['data'].first
      expect(entry['attempt_count']).to eq(2)
      expect(entry['last_response_status']).to eq(200)
      expect(entry['last_duration_ms']).to eq(12)
      expect(entry['last_error_type']).to be_nil
      expect(Time.zone.parse(entry['last_attempt_at'])).to be_within(1.second).of(latest.created_at)
    end

    it 'returns nil summary fields for a message without attempts' do
      create(:message, event: event, endpoint: endpoint)

      get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(maintainer)

      entry = JSON.parse(response.body)['data'].first
      expect(entry['attempt_count']).to eq(0)
      expect(entry['last_attempt_at']).to be_nil
      expect(entry['last_response_status']).to be_nil
      expect(entry['last_duration_ms']).to be_nil
      expect(entry['last_error_type']).to be_nil
    end

    it 'keeps the history of an archived endpoint readable' do
      endpoint.update!(archived_at: Time.current)
      message = create(:message, event: event, endpoint: endpoint)

      get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([message.id])
    end

    it 'does not let a non-member read the endpoint messages' do
      create(:message, event: event, endpoint: endpoint)

      get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end

    it 'does not expose an endpoint of another project through the requested project' do
      other_endpoint = create(:endpoint)

      get endpoint_messages_path(project.id, other_endpoint.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:not_found)
    end

    it 'never exposes signing secrets or credentials' do
      message = create(:message, event: event, endpoint: endpoint)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 200)

      get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(maintainer)

      expect(response.body).not_to include(endpoint.current_signing_secret.secret)
      expect(response.body).not_to include('token_digest')
      expect(JSON.parse(response.body)['data'].first).not_to have_key('attempts')
    end

    it 'keeps the number of payload queries bounded' do
      3.times do
        message = create(:message, event: create(:event, project: project), endpoint: endpoint)
        create(:delivery_attempt, message: message, attempt_number: 1, response_status: 200)
        create(:delivery_attempt, message: message, attempt_number: 2, response_status: 500)
      end

      query_count = payload_query_count do
        get endpoint_messages_path(project.id, endpoint.id), headers: auth_headers(maintainer)
      end

      expect(response).to have_http_status(:ok)
      expect(query_count).to be <= 4
    end
  end

  describe 'GET /api/v1/projects/:project_id/messages/:id' do
    let(:message) { create(:message, event: event, endpoint: endpoint) }

    it 'returns the message with its event, endpoint and ordered attempts' do
      create(:delivery_attempt, message: message, attempt_number: 2, response_status: 200, duration_ms: 12)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 503, duration_ms: 30)
      message.update_columns(attempt_count: 2)

      get message_path(project.id, message.id), headers: auth_headers(maintainer)

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body['id']).to eq(message.id)
      expect(body['webhook_id']).to eq(message.webhook_id)
      expect(body['status']).to eq('pending')
      expect(body['attempt_count']).to eq(2)
      expect(body['event']).to include(
        'id' => event.id,
        'event_type' => 'order.created',
        'payload' => { 'order_id' => 'ord_1' }
      )
      expect(Time.zone.parse(body['event']['created_at'])).to be_within(1.second).of(event.created_at)
      expect(body['endpoint']).to eq(
        'id' => endpoint.id,
        'name' => endpoint.name,
        'url' => endpoint.url,
        'project' => { 'id' => project.id, 'name' => project.name }
      )
      expect(body['attempts'].map { |attempt| attempt['attempt_number'] }).to eq([1, 2])
    end

    it 'derives the status of every attempt from its response' do
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 503)
      create(:delivery_attempt, message: message, attempt_number: 2, response_status: 204)

      get message_path(project.id, message.id), headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['attempts'].map { |attempt| attempt['status'] }).to eq(%w[failed succeeded])
    end

    it 'returns the evidence of a transport failure' do
      create(:delivery_attempt, message: message, attempt_number: 1,
                                error_type: 'Net::OpenTimeout', error_message: 'execution expired', duration_ms: 10_000)

      get message_path(project.id, message.id), headers: auth_headers(maintainer)

      attempt = JSON.parse(response.body)['attempts'].first
      expect(attempt['status']).to eq('failed')
      expect(attempt['response_status']).to be_nil
      expect(attempt['error_type']).to eq('Net::OpenTimeout')
      expect(attempt['error_message']).to eq('execution expired')
    end

    it 'exposes the signing secret version without the raw secret' do
      create(:delivery_attempt, message: message, attempt_number: 1, signing_secret_version: 2)

      get message_path(project.id, message.id), headers: auth_headers(maintainer)

      body = JSON.parse(response.body)
      expect(body['attempts'].first['signing_secret_version']).to eq(2)
      expect(response.body).not_to include(endpoint.current_signing_secret.secret)
    end

    it 'redacts the signature header from request evidence' do
      create(:delivery_attempt, message: message, attempt_number: 1,
                                request_headers: {
                                  'content-type' => 'application/json',
                                  'webhook-id' => message.webhook_id,
                                  'webhook-signature' => 'v1,top-secret-signature'
                                })

      get message_path(project.id, message.id), headers: auth_headers(maintainer)

      headers = JSON.parse(response.body)['attempts'].first['request_headers']
      expect(headers).not_to have_key('webhook-signature')
      expect(headers).to include('content-type' => 'application/json', 'webhook-id' => message.webhook_id)
    end

    it 'returns the persisted capped response body' do
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 200,
                                response_body: DeliveryAttempt.truncate_response_body('a' * 5000))

      get message_path(project.id, message.id), headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['attempts'].first['response_body'].bytesize)
        .to eq(DeliveryAttempt::RESPONSE_BODY_MAX_BYTES)
    end

    it 'does not expose a message from another project' do
      other_message = create(:message)

      get message_path(project.id, other_message.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:not_found)
    end

    it 'does not return a message of another project the user also belongs to' do
      other_project = create(:project, :with_owner, owner: owner)
      other_message = create(:message, project: other_project)

      get message_path(project.id, other_message.id), headers: auth_headers(owner)

      expect(response).to have_http_status(:not_found)
    end

    it 'reports an attempt without a response yet as in progress' do
      create(:delivery_attempt, message: message, attempt_number: 1)

      get message_path(project.id, message.id), headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['attempts'].first['status']).to eq('in_progress')
    end

    it 'does not let a non-member read the message' do
      message

      get message_path(project.id, message.id), headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end
end
