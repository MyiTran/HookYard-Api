require 'swagger_helper'

describe 'Projects::ApiCredentials', type: :request do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  describe 'GET /api/v1/projects/:project_id/api_credentials' do
    it 'lists the project credentials without exposing tokens or digests' do
      credential = create(:project_api_credential, project: project, name: 'Producer')

      get "/api/v1/projects/#{project.id}/api_credentials", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      entry = JSON.parse(response.body)['data'].first
      expect(entry['id']).to eq(credential.id)
      expect(entry['name']).to eq('Producer')
      expect(entry['token_hint']).to eq(credential.token_hint)
      expect(entry).not_to have_key('token')
      expect(entry).not_to have_key('token_digest')
    end

    it 'only lists credentials from the requested project' do
      create(:project_api_credential, project: project)
      create(:project_api_credential)

      get "/api/v1/projects/#{project.id}/api_credentials", headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].size).to eq(1)
    end

    it 'forbids a maintainer from listing credentials' do
      get "/api/v1/projects/#{project.id}/api_credentials", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
    end

    it 'hides credentials from a non-member' do
      get "/api/v1/projects/#{project.id}/api_credentials", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/projects/:project_id/api_credentials' do
    it 'creates a credential and returns the raw token once' do
      post "/api/v1/projects/#{project.id}/api_credentials",
           params: { api_credential: { name: 'Producer' } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['token']).to start_with(ProjectApiCredential::TOKEN_PREFIX)
      expect(body['name']).to eq('Producer')
      expect(body).not_to have_key('token_digest')
      expect(ProjectApiCredential.last.token_digest).to eq(Digest::SHA256.hexdigest(body['token']))
    end

    it 'forbids a maintainer from creating a credential' do
      expect do
        post "/api/v1/projects/#{project.id}/api_credentials",
             params: { api_credential: { name: 'Producer' } }, headers: auth_headers(maintainer), as: :json
      end.not_to change(ProjectApiCredential, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it 'hides the project from a non-member' do
      post "/api/v1/projects/#{project.id}/api_credentials",
           params: { api_credential: { name: 'Producer' } }, headers: auth_headers(outsider), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/projects/:project_id/api_credentials/:id/revoke' do
    let!(:credential) { create(:project_api_credential, project: project, name: 'Producer') }

    def revoke_path(project_id, credential_id)
      "/api/v1/projects/#{project_id}/api_credentials/#{credential_id}/revoke"
    end

    it 'revokes the credential without returning the raw token' do
      post revoke_path(project.id, credential.id), headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['id']).to eq(credential.id)
      expect(body['status']).to eq('revoked')
      expect(body['revoked_at']).to be_present
      expect(body).not_to have_key('token')
      expect(body).not_to have_key('token_digest')
      expect(credential.reload).to be_revoked
    end

    it 'shows the revoked credential in the listing with its status' do
      post revoke_path(project.id, credential.id), headers: auth_headers(owner)

      get "/api/v1/projects/#{project.id}/api_credentials", headers: auth_headers(owner)

      entry = JSON.parse(response.body)['data'].first
      expect(entry['status']).to eq('revoked')
      expect(entry['revoked_at']).to be_present
    end

    it 'rejects event ingestion with the revoked token immediately' do
      credential_record, raw_token = ProjectApiCredentials::Create.call(project: project, name: 'Producer')

      post revoke_path(project.id, credential_record.id), headers: auth_headers(owner)

      expect do
        post '/api/v1/events',
             params: { event_type: 'order.created', idempotency_key: 'order-1', payload: { order_id: 'ord_1' } },
             headers: { 'Authorization' => "Bearer #{raw_token}" }, as: :json
      end.not_to change(Event, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'forbids a maintainer from revoking a credential' do
      post revoke_path(project.id, credential.id), headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
      expect(credential.reload).not_to be_revoked
    end

    it 'hides the project from a non-member' do
      post revoke_path(project.id, credential.id), headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end

    it 'does not revoke a credential of another project' do
      foreign_credential = create(:project_api_credential)

      post revoke_path(project.id, foreign_credential.id), headers: auth_headers(owner)

      expect(response).to have_http_status(:not_found)
      expect(foreign_credential.reload).not_to be_revoked
    end
  end
end
