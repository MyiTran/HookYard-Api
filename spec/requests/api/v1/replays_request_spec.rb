require 'swagger_helper'

describe 'Webhook replays', type: :request do
  let(:owner) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:failed_message) { create(:message, event: event, endpoint: endpoint, status: :failed) }

  describe 'POST /api/v1/messages/:id/replay' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        post "/api/v1/messages/#{failed_message.id}/replay"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the user is a project member' do
      it 'accepts the replay and returns the audited run with its item' do
        post "/api/v1/messages/#{failed_message.id}/replay", headers: auth_headers(owner)

        expect(response).to have_http_status(:accepted)

        payload = json_response
        expect(payload).to include(
          'mode' => ReplayRun::MODE_SINGLE,
          'project_id' => project.id,
          'status' => ReplayRun::STATUS_RUNNING,
          'actor' => { 'id' => owner.id, 'name' => owner.name }
        )
        expect(payload['summary']).to include(
          'requested' => 1, 'eligible' => 1, 'queued' => 1, 'succeeded' => 0, 'failed' => 0, 'skipped' => 0
        )
        expect(payload['items'].one?).to be(true)
        expect(payload['items'].first).to include('message_id' => failed_message.id,
                                                  'status' => ReplayItem::QUEUED_STATUS)
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).to include(Replays::DeliverJob)
      end

      it 'rejects a message that is not terminally failed' do
        pending_message = create(:message, project: project, endpoint: endpoint, status: :pending)

        post "/api/v1/messages/#{pending_message.id}/replay", headers: auth_headers(owner)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response['errors']).to eq(
          [{ 'field' => 'message', 'message' => Replays::Eligibility::REASON_NOT_TERMINAL }]
        )
      end

      it 'rejects single replay when the endpoint is paused' do
        endpoint.update!(active: false)

        post "/api/v1/messages/#{failed_message.id}/replay", headers: auth_headers(owner)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response).to include(
          'message' => 'This endpoint is paused. Resume it before replaying this delivery.',
          'errors' => [{ 'field' => 'message', 'message' => 'endpoint_paused' }]
        )
        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(DeliveryAttempt.count).to eq(0)
        expect(failed_message.reload).to be_failed
      end
    end

    context 'when the message belongs to another project' do
      it 'returns not found without leaking the message' do
        post "/api/v1/messages/#{failed_message.id}/replay", headers: auth_headers(outsider)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/projects/:project_id/replays/preview' do
    it 'reports the eligible and blocked counts for the filters' do
      failed_message
      disabled = create(:endpoint, project: project, circuit_state: :disabled)
      create(:message, project: project, endpoint: disabled, status: :failed)
      create(:message, project: project, endpoint: endpoint, status: :succeeded)

      post "/api/v1/projects/#{project.id}/replays/preview", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(json_response).to include('requested_count' => 2, 'eligible_count' => 1, 'blocked_count' => 1,
                                       'max_items_per_run' => 20_000, 'over_limit' => false)
      expect(json_response['sample'].first).to include(
        'message_id' => failed_message.id,
        'event_type' => event.event_type,
        'endpoint' => { 'id' => endpoint.id, 'name' => endpoint.name }
      )
    end

    it 'flags a preview that would exceed the per-run cap' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2)
      create_list(:message, 3, project: project, endpoint: endpoint, status: :failed)

      post "/api/v1/projects/#{project.id}/replays/preview", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(json_response).to include(
        'eligible_count' => 3,
        'max_items_per_run' => 2,
        'over_limit' => true
      )
    end

    it 'reports paused endpoint candidates as blocked rather than eligible' do
      paused_endpoint = create(:endpoint, project: project, active: false)
      create_list(:message, 2, project: project, endpoint: paused_endpoint, status: :failed)

      post "/api/v1/projects/#{project.id}/replays/preview",
           headers: auth_headers(owner),
           params: { endpoint_id: paused_endpoint.id }

      expect(response).to have_http_status(:ok)
      expect(json_response).to include(
        'requested_count' => 2,
        'eligible_count' => 0,
        'blocked_count' => 2,
        'sample' => []
      )
    end

    it 'does not let outsiders preview another project' do
      post "/api/v1/projects/#{project.id}/replays/preview", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/projects/:project_id/replays' do
    let(:pro_owner) { create(:user, :pro) }
    let(:pro_project) { create(:project, :with_owner, owner: pro_owner) }
    let(:pro_endpoint) { create(:endpoint, project: pro_project) }

    it 'accepts a bulk replay for a pro plan project and freezes the confirmed candidate set' do
      message = create(:message, project: pro_project, endpoint: pro_endpoint, status: :failed)

      post "/api/v1/projects/#{pro_project.id}/replays", headers: auth_headers(pro_owner),
                                                        params: { event_type: 'order.created', unknown: 'ignored' }

      expect(response).to have_http_status(:accepted)

      payload = json_response
      expect(payload['mode']).to eq(ReplayRun::MODE_BULK)
      expect(payload['status']).to eq(ReplayRun::STATUS_QUEUED)
      expect(payload['filters']).to eq('event_type' => 'order.created')
      expect(payload['summary']).to include('requested' => 1, 'eligible' => 1, 'blocked' => 0, 'queued' => 1)
      expect(ReplayRun.find(payload['id']).replay_items.pluck(:message_id)).to eq([message.id])
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).to include(Replays::BulkJob)
    end

    it 'rejects the bulk replay on the free plan' do
      post "/api/v1/projects/#{project.id}/replays", headers: auth_headers(owner)

      expect(response).to have_http_status(:forbidden)
      expect(ReplayRun.count).to eq(0)
    end

    it 'does not let outsiders start a bulk replay' do
      post "/api/v1/projects/#{pro_project.id}/replays", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end

    context 'when the confirmation exceeds the per-run cap' do
      before { stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2) }

      it 'rejects the run with the limit details and without side effects' do
        create_list(:message, 3, project: pro_project, endpoint: pro_endpoint, status: :failed)

        post "/api/v1/projects/#{pro_project.id}/replays", headers: auth_headers(pro_owner)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response).to include(
          'code' => 'bulk_replay_limit_exceeded',
          'status' => 422,
          'eligible' => 3,
          'limit' => 2
        )
        expect(json_response['message']).to include('3 eligible deliveries')
        expect(json_response['errors'].first).to include('field' => 'base', 'message' => json_response['message'])
        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(DeliveryAttempt.count).to eq(0)
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] }).not_to include(Replays::BulkJob)
      end
    end
  end

  describe 'GET /api/v1/projects/:project_id/replays/:id' do
    let(:run) { create(:replay_run, :bulk, project: project, actor: owner) }

    it 'returns the audit metadata and the summary' do
      message = create(:message, project: project, endpoint: endpoint, status: :failed)
      create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                           status: ReplayItem::SUCCEEDED_STATUS, completed_at: Time.current)
      run.update!(requested_count: 2, materialized_at: Time.current)

      get "/api/v1/projects/#{project.id}/replays/#{run.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(json_response).to include(
        'id' => run.id,
        'mode' => ReplayRun::MODE_BULK,
        'status' => ReplayRun::STATUS_COMPLETED,
        'summary' => {
          'requested' => 2, 'eligible' => 1, 'blocked' => 1,
          'queued' => 0, 'held' => 0, 'delivering' => 0,
          'succeeded' => 1, 'failed' => 0, 'skipped' => 0
        }
      )
    end

    it 'does not expose the run to outsiders' do
      get "/api/v1/projects/#{project.id}/replays/#{run.id}", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'message delivery log' do
    it 'marks replayed attempts and reports the replay eligibility' do
      replay_run = create(:replay_run, project: project, actor: owner)
      item = create(:replay_item, replay_run: replay_run, message: failed_message, endpoint: endpoint,
                                  status: ReplayItem::SUCCEEDED_STATUS, completed_at: Time.current)
      failed_message.update!(status: :succeeded, terminal_at: Time.current)
      create(:delivery_attempt, message: failed_message, attempt_number: 9, replay_item: item, response_status: 204)
      create(:delivery_attempt, message: failed_message, attempt_number: 1, response_status: 500)

      get "/api/v1/projects/#{project.id}/messages/#{failed_message.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)

      attempts = json_response['attempts']
      expect(attempts.map { |attempt| attempt['attempt_kind'] }).to eq(%w[automatic replay])
      expect(attempts.last['replay_item_id']).to eq(item.id)
      expect(json_response['replay']).to include(
        'allowed' => false,
        'blocked_reason' => Replays::Eligibility::REASON_NOT_FAILED,
        'active' => false,
        'last_outcome' => include('id' => item.id, 'status' => ReplayItem::SUCCEEDED_STATUS)
      )
    end
  end

  describe 'message after a successful replay' do
    let(:http_client) { double('http_client') }
    let(:replay_run) { create(:replay_run, project: project, actor: owner) }
    let(:item) { create(:replay_item, replay_run: replay_run, message: failed_message, endpoint: endpoint) }

    before do
      failed_message.update!(attempt_count: 8, terminal_at: 1.hour.ago)
      create(:delivery_attempt, message: failed_message, attempt_number: 8, response_status: 500)
      allow(http_client).to receive(:post).and_return(
        Webhooks::HttpClient::Result.new(status: 200, headers: {}, body: '{"ok":true}', duration_ms: 5,
                                         error: nil, error_type: nil)
      )

      Replays::Deliver.new(http_client: http_client).call(item: item)
    end

    it 'reports the message as succeeded with the full attempt history in the detail endpoint' do
      get "/api/v1/projects/#{project.id}/messages/#{failed_message.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(json_response['status']).to eq('succeeded')
      expect(json_response['attempt_count']).to eq(8)
      expect(json_response['replay']).to include(
        'allowed' => false,
        'blocked_reason' => Replays::Eligibility::REASON_NOT_FAILED,
        'active' => false,
        'last_outcome' => include('status' => ReplayItem::SUCCEEDED_STATUS)
      )

      attempts = json_response['attempts']
      expect(attempts.map { |attempt| attempt['attempt_kind'] }).to eq(%w[automatic replay])
      expect(attempts.first['response_status']).to eq(500)
      expect(attempts.last['response_status']).to eq(200)
      expect(attempts.last['replay_item_id']).to eq(item.id)
    end

    it 'lists the message under the succeeded status filter and not under failed' do
      get '/api/v1/messages', headers: auth_headers(owner), params: { status: 'succeeded' }

      expect(json_response['data'].map { |message| message['id'] }).to include(failed_message.id)
      expect(json_response['data'].first['status']).to eq('succeeded')

      get '/api/v1/messages', headers: auth_headers(owner), params: { status: 'failed' }

      expect(json_response['data'].map { |message| message['id'] }).not_to include(failed_message.id)
    end
  end
end
