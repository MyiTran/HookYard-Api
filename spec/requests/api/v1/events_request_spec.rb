require 'swagger_helper'

describe 'Events', type: :request do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }
  let(:raw_token) { ProjectApiCredential.generate_token }
  let!(:credential) { create(:project_api_credential, project: project, raw_token: raw_token) }
  let(:headers) { { 'Authorization' => "Bearer #{raw_token}" } }
  let(:event_attributes) do
    { event_type: 'order.created', idempotency_key: 'order-1', payload: { order_id: 'ord_1' } }
  end

  before { clear_enqueued_jobs }

  describe 'POST /api/v1/events' do
    it 'accepts an event and fans out to every matching endpoint' do
      create_list(:endpoint, 12, project: project, event_types: ['order.created'])

      post '/api/v1/events', params: event_attributes, headers: headers, as: :json

      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body['status']).to eq('accepted')
      expect(body['event_type']).to eq('order.created')
      expect(body['messages_count']).to eq(12)
      expect(body['id']).to be_present
      expect(Event.where(project: project).count).to eq(1)
      expect(Message.count).to eq(12)
    end

    it 'includes endpoints subscribed to all events and excludes non-matching ones' do
      create(:endpoint, project: project, event_types: ['*'])
      create(:endpoint, project: project, event_types: ['order.created'])
      create(:endpoint, project: project, event_types: ['payment.failed'])

      post '/api/v1/events', params: event_attributes, headers: headers, as: :json

      expect(JSON.parse(response.body)['messages_count']).to eq(2)
    end

    it 'excludes inactive, archived and foreign project endpoints' do
      create(:endpoint, project: project, event_types: ['order.created'], active: false)
      create(:endpoint, project: project, event_types: ['order.created'], archived_at: Time.current)
      create(:endpoint, event_types: ['order.created'])

      post '/api/v1/events', params: event_attributes, headers: headers, as: :json

      expect(JSON.parse(response.body)['messages_count']).to eq(0)
      expect(Message.count).to eq(0)
    end

    it 'derives the project from the credential and ignores client supplied identifiers' do
      other_project = create(:project)
      other_endpoint = create(:endpoint, project: other_project, event_types: ['order.created'])
      create(:endpoint, project: project, event_types: ['order.created'])

      post '/api/v1/events',
           params: event_attributes.merge(project_id: other_project.id, endpoint_id: other_endpoint.id),
           headers: headers, as: :json

      expect(response).to have_http_status(:accepted)
      expect(Event.last.project).to eq(project)
      expect(Message.where(endpoint: other_endpoint)).not_to exist
    end

    it 'enqueues delivery jobs without delivering synchronously' do
      create(:endpoint, project: project, event_types: ['order.created'])
      expect(Messages::Deliver).not_to receive(:call)

      expect { post '/api/v1/events', params: event_attributes, headers: headers, as: :json }
        .to have_enqueued_job(Messages::DeliverJob).exactly(1).times
    end

    it 'returns the same event for a repeated idempotency key without new messages' do
      create(:endpoint, project: project, event_types: ['order.created'])
      post '/api/v1/events', params: event_attributes, headers: headers, as: :json
      first_id = JSON.parse(response.body)['id']
      clear_enqueued_jobs

      expect { post '/api/v1/events', params: event_attributes, headers: headers, as: :json }
        .not_to change { [Event.count, Message.count] }

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body['id']).to eq(first_id)
      expect(body['status']).to eq('duplicate')
      expect(body['messages_count']).to eq(0)
      expect(Event.where(project: project).count).to eq(1)
      expect(Message.count).to eq(1)
    end

    it 're-enqueues the pending messages of a repeated idempotency key' do
      create(:endpoint, project: project, event_types: ['order.created'])
      post '/api/v1/events', params: event_attributes, headers: headers, as: :json
      message = Message.last
      clear_enqueued_jobs

      expect { post '/api/v1/events', params: event_attributes, headers: headers, as: :json }
        .to have_enqueued_job(Messages::DeliverJob).with(message.id)
    end

    it 'rejects a reused idempotency key with different content' do
      post '/api/v1/events', params: event_attributes, headers: headers, as: :json

      post '/api/v1/events',
           params: event_attributes.merge(payload: { order_id: 'ord_2' }), headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['message']).to eq('Idempotency key already used with a different request')
    end

    it 'rejects a missing event type' do
      post '/api/v1/events', params: event_attributes.except(:event_type), headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a missing idempotency key' do
      post '/api/v1/events', params: event_attributes.except(:idempotency_key), headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a payload that is not a JSON object' do
      post '/api/v1/events', params: event_attributes.merge(payload: [1, 2]), headers: headers, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    context 'when the credential is missing or invalid' do
      it 'returns unauthorized without a credential' do
        post '/api/v1/events', params: event_attributes, as: :json

        expect(response).to have_http_status(:unauthorized)
        expect(Event.count).to eq(0)
      end

      it 'returns unauthorized for an unknown token' do
        post '/api/v1/events', params: event_attributes,
             headers: { 'Authorization' => "Bearer #{ProjectApiCredential.generate_token}" }, as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns unauthorized for a revoked credential' do
        credential.update!(revoked_at: Time.current)

        post '/api/v1/events', params: event_attributes, headers: headers, as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    it 'never exposes credentials or signing secrets in the response' do
      create(:endpoint, project: project, event_types: ['order.created'])

      post '/api/v1/events', params: event_attributes, headers: headers, as: :json

      body = JSON.parse(response.body)
      expect(body.keys).to contain_exactly('id', 'event_type', 'status', 'messages_count', 'created_at')
      expect(response.body).not_to include(raw_token)
      expect(response.body).not_to include(credential.token_digest)
    end
  end
end
