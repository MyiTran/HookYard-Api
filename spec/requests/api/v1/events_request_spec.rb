require 'swagger_helper'

describe 'Events', type: :request do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project, event_types: [Endpoint::WILDCARD_EVENT_TYPE]) }
  let(:raw_token) { ProjectApiCredential.create_with_token!(project: project, name: 'CI').last }
  let(:headers) { { 'Authorization' => "Bearer #{raw_token}" } }
  let(:event_params) do
    {
      event_type: 'order.created',
      idempotency_key: SecureRandom.uuid,
      payload: { 'order_id' => SecureRandom.uuid }
    }
  end

  before { endpoint }

  describe 'POST /api/v1/events' do
    context 'when the project is below its monthly delivery limit' do
      it 'accepts the event and meters the fan out' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:accepted)
        expect(project.reload.deliveries_used_in_period).to eq(1)
      end
    end

    context 'when the project reached its monthly delivery limit' do
      before do
        limit = Plans::Entitlements.monthly_delivery_limit(project)
        ProjectUsagePeriod.reserve_deliveries(project: project, quantity: limit, limit: limit)
      end

      it 'rejects the event with a payment required contract' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(response).to have_http_status(:payment_required)
        limit = Plans::Entitlements.monthly_delivery_limit(project)
        body = JSON.parse(response.body)
        expect(body['error']).to eq('plan_limit_exceeded')
        expect(body['message']).to eq("The #{project.plan} plan allows at most #{limit} deliveries per month")
        expect(body['status']).to eq(402)
        expect(body['used']).to eq(limit)
        expect(body['limit']).to eq(limit)
        expect(body['period_ends']).to eq(ProjectUsagePeriod.period_ends_at.iso8601)
        expect(body['errors']).to contain_exactly(hash_including('field' => 'monthly_delivery_limit'))
      end

      it 'persists the rejection instead of the event after the transaction rolls back' do
        post '/api/v1/events', params: event_params, headers: headers, as: :json

        expect(project.events.count).to eq(0)
        expect(Message.count).to eq(0)
        rejection = project.ingest_rejections.sole
        expect(rejection.reason).to eq(IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED)
        expect(rejection.idempotency_key_digest).to eq(Digest::SHA256.hexdigest(event_params[:idempotency_key]))
        expect(rejection.payload).to eq(event_params[:payload])
      end

      it 'accepts the event again once the plan allows it' do
        project.update!(plan: Project::PRO_PLAN)

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
