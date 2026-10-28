require 'swagger_helper'

describe 'Events', type: :request do
  let(:project) { create(:project) }
  let!(:endpoint) { create(:endpoint, project: project, event_types: ['*']) }
  let(:token) { ProjectApiCredential.create_with_token!(project: project, name: 'Ingest').last }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:idempotency_key) { "event-#{SecureRandom.uuid}" }
  let(:payload) do
    {
      event_type: 'order.created',
      idempotency_key: idempotency_key,
      payload: { 'order_id' => SecureRandom.uuid }
    }
  end

  describe 'POST /api/v1/events' do
    context 'when the endpoint queue has room' do
      it 'accepts the event and counts the created message' do
        post '/api/v1/events', params: payload, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(json_response).to include('status' => 'accepted', 'messages_count' => 1)
        expect(endpoint.reload.queued_message_count).to eq(1)
        expect(project.events.count).to eq(1)
      end

      it 'reports a duplicate request without creating more messages' do
        post '/api/v1/events', params: payload, headers: headers, as: :json
        post '/api/v1/events', params: payload, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response).to include('status' => 'duplicate', 'messages_count' => 0)
        expect(project.events.count).to eq(1)
        expect(endpoint.reload.queued_message_count).to eq(1)
      end
    end

    context 'when an eligible endpoint queue is full' do
      before { endpoint.update_columns(queued_message_count: Webhooks::CircuitPolicy::QUEUE_CAPACITY) }

      it 'rejects the event with a retry hint and records the rejection' do
        post '/api/v1/events', params: payload, headers: headers, as: :json

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers['Retry-After']).to eq('30')
        expect(json_response).to include(
          'code' => 'queue_capacity_exceeded',
          'status' => 429
        )
        expect(project.events.count).to eq(0)
        expect(Message.where(endpoint_id: endpoint.id).count).to eq(0)
        expect(IngestRejection.sole.reason).to eq('queue_capacity_exceeded')
      end

      it 'accepts the same idempotency key once capacity is available again' do
        post '/api/v1/events', params: payload, headers: headers, as: :json
        expect(response).to have_http_status(:too_many_requests)

        endpoint.update_columns(queued_message_count: 0)
        post '/api/v1/events', params: payload, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(project.events.count).to eq(1)
      end
    end

    context 'when the endpoint circuit is open' do
      before do
        endpoint.update!(
          circuit_state: 'circuit_open',
          circuit_failure_count: 5,
          circuit_opened_at: Time.current,
          circuit_next_probe_at: Time.current
        )
      end

      it 'accepts the event and holds the message without enqueueing delivery' do
        post '/api/v1/events', params: payload, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(endpoint.messages.sole).to be_held
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end
    end
  end
end
