require 'swagger_helper'

describe 'Ingest rejections', type: :request do
  let(:owner) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:raw_idempotency_key) { 'super-secret-idempotency-key' }
  let!(:rejection) do
    create(
      :ingest_rejection,
      project: project,
      endpoint: endpoint,
      reason: IngestRejection::QUEUE_CAPACITY_EXCEEDED,
      event_type: 'order.created',
      idempotency_key_digest: IngestRejection.digest_idempotency_key(raw_idempotency_key)
    )
  end

  describe 'GET /api/v1/ingest_rejections' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/ingest_rejections'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when authenticated' do
      it 'returns only rejections of accessible projects' do
        create(:ingest_rejection, project: create(:project, :with_owner, owner: outsider))

        get '/api/v1/ingest_rejections', headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(rejection.id)
      end

      it 'serializes safe rejection metadata only' do
        get '/api/v1/ingest_rejections', headers: auth_headers(owner)

        entry = json_response['data'].first
        expect(entry).to include(
          'id' => rejection.id,
          'reason' => IngestRejection::QUEUE_CAPACITY_EXCEEDED,
          'event_type' => 'order.created',
          'project' => { 'id' => project.id, 'name' => project.name },
          'endpoint' => { 'id' => endpoint.id, 'name' => endpoint.name },
          'payload_keys' => %w[order_id],
          'payload_bytes' => 42
        )
        expect(entry['created_at']).to be_present
        expect(entry.keys).to contain_exactly(
          'id', 'reason', 'event_type', 'created_at', 'project', 'endpoint', 'payload_keys', 'payload_bytes'
        )
      end

      it 'never exposes the idempotency key or its digest' do
        get '/api/v1/ingest_rejections', headers: auth_headers(owner)

        expect(response.body).not_to include(raw_idempotency_key)
        expect(response.body).not_to include(IngestRejection.digest_idempotency_key(raw_idempotency_key))
        expect(response.body).not_to include('idempotency')
      end

      it 'filters by reason, event type and creation date' do
        monthly = create(
          :ingest_rejection,
          project: project,
          reason: IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED,
          event_type: 'invoice.paid',
          created_at: 2.days.ago
        )

        get '/api/v1/ingest_rejections',
            params: { reason: IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED },
            headers: auth_headers(owner)
        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(monthly.id)

        get '/api/v1/ingest_rejections', params: { event_type: 'order.created' }, headers: auth_headers(owner)
        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(rejection.id)

        get '/api/v1/ingest_rejections', params: { from: 1.day.ago.iso8601 }, headers: auth_headers(owner)
        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(rejection.id)
      end
    end
  end

  describe 'GET /api/v1/projects/:project_id/ingest_rejections' do
    context 'when the user belongs to the project' do
      it 'lists the project rejections' do
        get "/api/v1/projects/#{project.id}/ingest_rejections", headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(rejection.id)
      end
    end

    context 'when the user is outside the project' do
      it 'is not found' do
        get "/api/v1/projects/#{project.id}/ingest_rejections", headers: auth_headers(outsider)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'GET /api/v1/admin/ingest_rejections' do
    let(:admin) { create(:user).tap { |user| user.add_role(:admin) } }

    context 'when the user is a global admin' do
      it 'lists rejections of projects the admin does not belong to' do
        get '/api/v1/admin/ingest_rejections', headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(rejection.id)
      end

      it 'filters by project' do
        create(:ingest_rejection, project: create(:project))

        get '/api/v1/admin/ingest_rejections', params: { project_id: project.id }, headers: auth_headers(admin)

        expect(json_response['data'].map { |entry| entry['id'] }).to contain_exactly(rejection.id)
      end
    end

    context 'when the user is a project owner without the global admin role' do
      it 'is forbidden' do
        get '/api/v1/admin/ingest_rejections', headers: auth_headers(owner)

        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
