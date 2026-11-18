require 'swagger_helper'

describe 'Projects::Replays', type: :request do
  let(:owner) { create(:user, :pro) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :pro, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project, event_type: 'order.created') }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  def preview_path(project_id)
    "/api/v1/projects/#{project_id}/replays/preview"
  end

  def replays_path(project_id)
    "/api/v1/projects/#{project_id}/replays"
  end

  def replay_path(project_id, run_id)
    "/api/v1/projects/#{project_id}/replays/#{run_id}"
  end

  def failed_message
    create(:message, project: project, endpoint: endpoint, event: event, status: :failed,
                     terminal_at: Time.current)
  end

  describe 'POST /api/v1/projects/:project_id/replays/preview' do
    it 'returns the recovery preview for a member' do
      message = failed_message

      post preview_path(project.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['requested_count']).to eq(1)
      expect(body['eligible_count']).to eq(1)
      expect(body['blocked_count']).to eq(0)
      expect(body['sample'].first['message_id']).to eq(message.id)
      expect(body['max_items_per_run']).to eq(Replays::BulkPolicy::MAX_ITEMS_PER_RUN)
    end

    it 'does not expose the endpoint signing secret' do
      failed_message

      post preview_path(project.id), headers: auth_headers(maintainer)

      expect(response.body).not_to include(endpoint.current_signing_secret.secret)
    end

    it 'does not let a non-member preview a recovery' do
      post preview_path(project.id), headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/projects/:project_id/replays' do
    it 'creates a queued bulk replay run without materializing candidates' do
      failed_message

      post replays_path(project.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body['mode']).to eq(ReplayRun::MODE_BULK)
      expect(body['project_id']).to eq(project.id)
      expect(body['status']).to eq(ReplayRun::STATUS_QUEUED)
      expect(body['requested_count']).to eq(0)
      expect(body['as_of']).to be_present
      expect(ReplayItem.count).to eq(0)
    end

    it 'does not let a non-member create a recovery' do
      post replays_path(project.id), headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end

    it 'rejects bulk replay on a free plan' do
      free_owner = create(:user)
      free_project = create(:project, :with_owner, owner: free_owner)

      post replays_path(free_project.id), headers: auth_headers(free_owner)

      expect(response).to have_http_status(:forbidden)
    end

    it 'accepts a bulk replay when the monthly limit is already reached and defers the failure to the job' do
      failed_message
      account = project.effective_billing_owner
      limit = Plans::Entitlements.monthly_delivery_limit(account)
      UserUsagePeriod.reserve_deliveries!(user: account, quantity: limit, limit: limit)

      post replays_path(project.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:accepted)
      body = JSON.parse(response.body)
      expect(body['status']).to eq(ReplayRun::STATUS_QUEUED)
      expect(body['requested_count']).to eq(0)
      expect(ReplayItem.count).to eq(0)
    end
  end

  describe 'GET /api/v1/projects/:project_id/replays/:id' do
    it 'returns the replay run to a member' do
      run = create(:replay_run, project: project, actor: maintainer, mode: ReplayRun::MODE_SINGLE,
                                requested_count: 1, materialized_at: Time.current)

      get replay_path(project.id, run.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['id']).to eq(run.id)
      expect(body['summary']).to include('requested' => 1, 'eligible' => 0)
    end

    it 'does not expose a replay run of another project' do
      other_project = create(:project, :with_owner, owner: owner)
      run = create(:replay_run, project: other_project, actor: owner)

      get replay_path(project.id, run.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:not_found)
    end

    it 'returns a failed run with its failure reason' do
      run = create(:replay_run, project: project, actor: maintainer, mode: ReplayRun::MODE_BULK,
                                materialized_at: nil, requested_count: 0,
                                failed_at: Time.current, failure_reason: ReplayRun::FAILURE_REASON_QUOTA)

      get replay_path(project.id, run.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['status']).to eq(ReplayRun::STATUS_FAILED)
      expect(body['failure_reason']).to eq(ReplayRun::FAILURE_REASON_QUOTA)
      expect(body['failed_at']).to be_present
    end
  end
end
