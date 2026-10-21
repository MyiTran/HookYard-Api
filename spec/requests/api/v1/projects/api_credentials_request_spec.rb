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
end
