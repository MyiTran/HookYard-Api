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
          'retryable' => true,
          'delivery_state' => 'scheduled_retry',
          'hold' => nil
        )
        expect(entry['next_retry_at']).to be_present
        expect(entry['terminal_at']).to be_nil
        expect(entry.keys).not_to include('delivery_lease_expires_at')
      end

      it 'reports a rejected destination as its own failure category' do
        create(
          :delivery_attempt,
          message: message,
          attempt_number: 1,
          error_type: 'Webhooks::DestinationResolver::NotPubliclyRoutable',
          error_message: 'destination is not publicly routable'
        )

        get '/api/v1/messages', headers: auth_headers(owner)

        expect(json_response['data'].first).to include(
          'failure_category' => 'destination_rejected',
          'last_error_type' => 'Webhooks::DestinationResolver::NotPubliclyRoutable'
        )
        expect(response.body).not_to match(/\b\d{1,3}(\.\d{1,3}){3}\b/)
      end

      it 'serializes a circuit-held message without exposing internal tracking fields' do
        message.update_columns(held_at: Time.current, hold_reason: 'endpoint_circuit_open')

        get '/api/v1/messages', headers: auth_headers(owner)

        entry = json_response['data'].first
        expect(entry['delivery_state']).to eq('held_by_circuit')
        expect(entry['hold']).to include('reason' => 'endpoint_circuit_open', 'release_at' => nil)
        expect(entry['hold']['since']).to be_present
        expect(entry.keys).not_to include('held_at', 'hold_reason', 'queued_at')
      end

      it 'does not expose circuit internals on the endpoint of a message' do
        message

        get '/api/v1/messages', headers: auth_headers(owner)

        endpoint_payload = json_response['data'].first['endpoint']

        expect(endpoint_payload.keys).to contain_exactly('id', 'name', 'url')
      end
    end

    context 'when filtering by delivery state' do
      let!(:circuit_open_message) do
        create(:message, project: project).tap { |record| record.hold!(reason: 'endpoint_circuit_open') }
      end
      let!(:disabled_endpoint_message) do
        create(:message, project: project).tap { |record| record.hold!(reason: 'endpoint_disabled') }
      end

      def listed_ids
        json_response['data'].map { |entry| entry['id'] }
      end

      it 'returns messages held by an open circuit and by a disabled endpoint' do
        get '/api/v1/messages', params: { delivery_state: 'held_by_circuit' }, headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(listed_ids).to contain_exactly(circuit_open_message.id, disabled_endpoint_message.id)
        expect(json_response['data'].map { |entry| entry['delivery_state'] }).to all(eq('held_by_circuit'))
      end

      it 'excludes queued, retry-scheduled, delivering and terminal messages' do
        queued = create(:message, project: project)
        retry_scheduled = create(:message, project: project, next_retry_at: 1.minute.from_now)
        delivering = create(:message, project: project)
        delivering.update_columns(status: 'delivering', delivery_lease_expires_at: 1.minute.from_now)
        terminal = create(:message, project: project, status: :failed, terminal_at: Time.current)

        get '/api/v1/messages', params: { delivery_state: 'held_by_circuit' }, headers: auth_headers(owner)

        expect(listed_ids).not_to include(queued.id, retry_scheduled.id, delivering.id, terminal.id)
      end

      it 'excludes pending messages of a paused endpoint that are not held' do
        paused_endpoint = create(:endpoint, project: project, active: false)
        paused_message = create(:message, event: create(:event, project: project), endpoint: paused_endpoint)

        get '/api/v1/messages', params: { delivery_state: 'held_by_circuit' }, headers: auth_headers(owner)

        expect(listed_ids).not_to include(paused_message.id)
      end

      it 'narrows held messages with the project and endpoint filters' do
        other_endpoint = create(:endpoint, project: project)
        other_endpoint_message = create(:message, event: create(:event, project: project), endpoint: other_endpoint)
        other_endpoint_message.hold!(reason: 'endpoint_circuit_open')
        other_project = create(:project, :with_owner, owner: owner)
        create(:message, project: other_project).hold!(reason: 'endpoint_circuit_open')

        get '/api/v1/messages',
            params: { delivery_state: 'held_by_circuit', project_id: project.id },
            headers: auth_headers(owner)

        expect(listed_ids).to contain_exactly(circuit_open_message.id, disabled_endpoint_message.id, other_endpoint_message.id)

        get '/api/v1/messages',
            params: { delivery_state: 'held_by_circuit', endpoint_id: other_endpoint.id },
            headers: auth_headers(owner)

        expect(listed_ids).to contain_exactly(other_endpoint_message.id)
      end

      it 'does not expose held messages of projects the user cannot access' do
        outsider_project = create(:project, :with_owner, owner: outsider)
        outsider_message = create(:message, project: outsider_project)
        outsider_message.hold!(reason: 'endpoint_circuit_open')

        get '/api/v1/messages', params: { delivery_state: 'held_by_circuit' }, headers: auth_headers(owner)

        expect(listed_ids).to contain_exactly(circuit_open_message.id, disabled_endpoint_message.id)
        expect(listed_ids).not_to include(outsider_message.id)
      end

      it 'paginates the filtered held messages' do
        create(:message, project: project).tap { |record| record.hold!(reason: 'endpoint_disabled') }

        get '/api/v1/messages',
            params: { delivery_state: 'held_by_circuit', page: { number: 1, size: 2 } },
            headers: auth_headers(owner)

        expect(json_response['data'].size).to eq(2)
        expect(json_response['meta']).to include(
          'page_number' => 1,
          'page_size' => 2,
          'total_count' => 3,
          'last_page' => 2
        )
      end

      it 'rejects an unsupported delivery state' do
        get '/api/v1/messages', params: { delivery_state: 'closed' }, headers: auth_headers(owner)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response).to include(
          'message' => 'Unsupported delivery state',
          'status' => 422,
          'errors' => [{ 'field' => 'delivery_state', 'message' => 'is not supported' }]
        )
      end
    end

    context 'when the delivery state is not requested' do
      it 'keeps returning every accessible message' do
        held = create(:message, project: project).tap { |record| record.hold!(reason: 'endpoint_circuit_open') }
        queued = create(:message, project: project)

        get '/api/v1/messages', headers: auth_headers(owner)

        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(held.id, queued.id)
        expect(json_response['meta']['total_count']).to eq(2)
      end

      it 'keeps the status filter independent from the hold tracking' do
        held = create(:message, project: project).tap { |record| record.hold!(reason: 'endpoint_disabled') }
        queued = create(:message, project: project)
        create(:message, project: project, status: :succeeded, terminal_at: Time.current)

        get '/api/v1/messages', params: { status: 'pending' }, headers: auth_headers(owner)

        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(held.id, queued.id)
        expect(json_response['data'].map { |entry| entry['delivery_state'] }).to contain_exactly('held_by_circuit', 'queued')
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
          'status' => 'pending',
          'delivery_state' => 'queued'
        )
        expect(json_response['attempts'].first['status']).to eq('failed')
        expect(json_response['attempts'].first['failure_category']).to eq('http_error')
        expect(json_response['failure_category']).to eq('http_error')
      end

      it 'distinguishes a rejected destination from a transport failure' do
        create(
          :delivery_attempt,
          message: message,
          attempt_number: 1,
          error_type: 'Webhooks::DestinationResolver::NotPubliclyRoutable',
          error_message: 'destination is not publicly routable'
        )
        create(
          :delivery_attempt,
          message: message,
          attempt_number: 2,
          error_type: 'Net::ReadTimeout',
          error_message: 'execution expired'
        )

        get "/api/v1/projects/#{project.id}/messages/#{message.id}", headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(json_response['failure_category']).to eq('timeout')
        expect(json_response['attempts'].map { |attempt| attempt['failure_category'] })
          .to eq(%w[destination_rejected timeout])
        expect(response.body).not_to match(/\b\d{1,3}(\.\d{1,3}){3}\b/)
      end

      it 'exposes the held delivery state of a circuit-held message' do
        message.update_columns(held_at: Time.current, hold_reason: 'endpoint_disabled')

        get "/api/v1/projects/#{project.id}/messages/#{message.id}", headers: auth_headers(owner)

        expect(json_response['delivery_state']).to eq('held_by_circuit')
        expect(json_response['hold']).to include('reason' => 'endpoint_disabled')
      end

      it 'exposes the terminal timestamp for a delivered message' do
        message.update_columns(status: 'succeeded', attempt_count: 1, terminal_at: Time.current)

        get "/api/v1/projects/#{project.id}/messages/#{message.id}", headers: auth_headers(owner)

        expect(json_response['status']).to eq('succeeded')
        expect(json_response['delivery_state']).to eq('terminal')
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
