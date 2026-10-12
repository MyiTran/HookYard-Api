require 'swagger_helper'

describe 'Projects' do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) do
    create(:project, :with_owner, owner: owner).tap do |created|
      create(:project_membership, project: created, user: maintainer, role: :maintainer)
    end
  end

  describe 'POST /api/v1/projects' do
    it 'creates the project and makes the creator its owner' do
      post '/api/v1/projects', params: { project: { name: 'Alpha' } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['name']).to eq('Alpha')
      expect(body['current_user_role']).to eq('owner')
      expect(Project.find(body['id']).project_memberships.pluck(:user_id, :role)).to eq([[owner.id, 'owner']])
    end

    it 'requires authentication' do
      post '/api/v1/projects', params: { project: { name: 'Alpha' } }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/projects' do
    it 'only lists projects the current user belongs to' do
      project
      create(:project, :with_owner)

      get '/api/v1/projects', headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([project.id])
    end
  end

  describe 'GET /api/v1/projects/:id' do
    it 'renders the current user role for a member' do
      get "/api/v1/projects/#{project.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['current_user_role']).to eq('maintainer')
    end

    it 'hides the project from a non-member' do
      get "/api/v1/projects/#{project.id}", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end

    it 'cannot reach another project by UUID' do
      other_project = create(:project, :with_owner)

      get "/api/v1/projects/#{other_project.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /api/v1/projects/:id' do
    it 'lets the owner update' do
      patch "/api/v1/projects/#{project.id}", params: { project: { name: 'Renamed' } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(project.reload.name).to eq('Renamed')
    end

    it 'forbids a maintainer' do
      patch "/api/v1/projects/#{project.id}", params: { project: { name: 'Renamed' } }, headers: auth_headers(maintainer), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(project.reload.name).not_to eq('Renamed')
    end

    it 'hides the project from a non-member' do
      patch "/api/v1/projects/#{project.id}", params: { project: { name: 'Renamed' } }, headers: auth_headers(outsider), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /api/v1/projects/:id' do
    it 'lets the owner delete' do
      delete "/api/v1/projects/#{project.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:no_content)
      expect(Project.exists?(project.id)).to be(false)
    end

    it 'forbids a maintainer' do
      delete "/api/v1/projects/#{project.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
      expect(Project.exists?(project.id)).to be(true)
    end
  end
end
