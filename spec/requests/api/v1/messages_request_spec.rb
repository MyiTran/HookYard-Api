require 'swagger_helper'

describe 'Messages', type: :request do
  let(:owner) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }

  describe 'GET /api/v1/messages' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/messages'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated' do
      it 'returns only messages from accessible projects' do
        message
        create(:message)

        get '/api/v1/messages', headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(message.id)
      end

      it 'serializes the retry lifecycle contract' do
        message.update_columns(attempt_count: 2, next_retry_at: 5.minutes.from_now)

        get '/api/v1/messages', headers: auth_headers(owner)

        entry = json_response['data'].first
        expect(entry).to include(
          'id' => message.id,
          'status' => 'pending',
          'attempt_count' => 2,
          'max_attempts' => Webhooks::DeliveryPolicy::MAX_ATTEMPTS,
          'retryable' => true
        )
        expect(entry['next_retry_at']).to be_present
        expect(entry['terminal_at']).to be_nil
        expect(entry.keys).not_to include('delivery_lease_expires_at')
      end
    end
  end

  describe 'GET /api/v1/projects/:project_id/messages/:id' do
    context 'when the message belongs to the project' do
      it 'returns the delivery lifecycle fields and attempts' do
        create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500)
        message.update_columns(attempt_count: 1)

        get "/api/v1/projects/#{project.id}/messages/#{message.id}", headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(json_response['id']).to eq(message.id)
        expect(json_response).to include(
          'attempt_count' => 1,
          'max_attempts' => Webhooks::DeliveryPolicy::MAX_ATTEMPTS,
          'status' => 'pending'
        )
        expect(json_response['attempts'].first['status']).to eq('failed')
      end

      it 'exposes the terminal timestamp for a delivered message' do
        message.update_columns(status: 'succeeded', attempt_count: 1, terminal_at: Time.current)

        get "/api/v1/projects/#{project.id}/messages/#{message.id}", headers: auth_headers(owner)

        expect(json_response['status']).to eq('succeeded')
        expect(json_response['terminal_at']).to be_present
        expect(json_response['retryable']).to be(false)
        expect(json_response.keys).not_to include('delivery_lease_expires_at')
      end
    end

    context 'when the message belongs to another project' do
      it 'is not found' do
        other_message = create(:message)

        get "/api/v1/projects/#{project.id}/messages/#{other_message.id}", headers: auth_headers(owner)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET /api/v1/projects/:project_id/endpoints/:endpoint_id/messages' do
    it 'lists the endpoint messages with the retry lifecycle fields' do
      message.update_columns(attempt_count: 1, next_retry_at: 1.minute.from_now)

      get "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/messages", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(message.id)
      expect(json_response['data'].first).to include('attempt_count' => 1, 'max_attempts' => Webhooks::DeliveryPolicy::MAX_ATTEMPTS)
    end
  end
end
