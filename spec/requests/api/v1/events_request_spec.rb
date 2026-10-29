require 'swagger_helper'

describe 'Events', type: :request do
  let(:project) { create(:project) }
  let!(:endpoint) { create(:endpoint, project: project, event_types: [Endpoint::WILDCARD_EVENT_TYPE]) }
  let(:raw_token) { ProjectApiCredential.create_with_token!(project: project, name: 'CI').last }
  let(:headers) { { 'Authorization' => "Bearer #{raw_token}" } }
  let(:idempotency_key) { "event-#{SecureRandom.uuid}" }
  let(:event_params) do
    {
      event_type: 'order.created',
      idempotency_key: idempotency_key,
      payload: { 'order_id' => SecureRandom.uuid }
    }
  end

  describe 'POST /api/v1/events' do
    context 'when the endpoint queue has room' do
      it 'accepts the event and counts the created message' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(json_response).to include('status' => 'accepted', 'messages_count' => 1)
        expect(endpoint.reload.queued_message_count).to eq(1)
        expect(project.events.count).to eq(1)
      end

      it 'reports a duplicate request without creating more messages' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response).to include('status' => 'duplicate', 'messages_count' => 0)
        expect(project.events.count).to eq(1)
        expect(endpoint.reload.queued_message_count).to eq(1)
      end
    end

    context 'when an eligible endpoint queue is full' do
      before { endpoint.update_columns(queued_message_count: Webhooks::CircuitPolicy::QUEUE_CAPACITY) }

      it 'rejects the event with a retry hint and records the rejection' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

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
        post '/api/v1/events', params: event_params, headers: headers, as: :json
        expect(response).to have_http_status(:too_many_requests)

        endpoint.update_columns(queued_message_count: 0)
        post '/api/v1/events', params: event_params, headers: headers, as: :json

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
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(endpoint.messages.sole).to be_held
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      end
    end

    context 'when the project is below its monthly delivery limit' do
      it 'accepts the event and meters the fan out' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(project.billing_owner.deliveries_used_in_period).to eq(1)
      end
    end

    context 'when the project reached its monthly delivery limit' do
      before do
        limit = Plans::Entitlements.monthly_delivery_limit(project.billing_owner)
        UserUsagePeriod.reserve_deliveries(user: project.billing_owner, quantity: limit, limit: limit)
      end

      it 'rejects the event with a payment required contract' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:payment_required)
        limit = Plans::Entitlements.monthly_delivery_limit(project.billing_owner)
        body = JSON.parse(response.body)
        expect(body['error']).to eq('plan_limit_exceeded')
        expect(body['message']).to eq("The #{project.plan} plan allows at most #{limit} deliveries per month")
        expect(body['status']).to eq(402)
        expect(body['used']).to eq(limit)
        expect(body['limit']).to eq(limit)
        expect(body['period_ends']).to eq(UserUsagePeriod.period_ends_at.iso8601)
        expect(body['errors']).to contain_exactly(hash_including('field' => 'monthly_delivery_limit'))
      end

      it 'persists the rejection instead of the event after the transaction rolls back' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(project.events.count).to eq(0)
        expect(Message.count).to eq(0)
        rejection = project.ingest_rejections.sole
        expect(rejection.reason).to eq(IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED)
        expect(rejection.idempotency_key_digest).to eq(Digest::SHA256.hexdigest(event_params[:idempotency_key]))
        expect(rejection.payload).to eq(
          'payload_keys' => ['order_id'],
          'payload_bytes' => event_params[:payload].to_json.bytesize
        )
      end

      it 'accepts the event again once the plan allows it' do
        project.billing_owner.update!(plan: User::PRO_PLAN)

        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(project.events.count).to eq(1)
      end
    end

    context 'when the request is unauthenticated' do
      it 'requires project credentials' do
        post '/api/v1/events', params: event_params, as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
