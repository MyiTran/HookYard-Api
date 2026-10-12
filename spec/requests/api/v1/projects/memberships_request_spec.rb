require 'swagger_helper'

describe 'Projects::Memberships' do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let!(:maintainer_membership) { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  describe 'GET /api/v1/projects/:project_id/memberships' do
    it 'lets a member list collaborators' do
      get "/api/v1/projects/#{project.id}/memberships", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['role'] }).to contain_exactly('owner', 'maintainer')
    end

    it 'hides collaborators from a non-member' do
      get "/api/v1/projects/#{project.id}/memberships", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /api/v1/projects/:project_id/memberships/:id' do
    it 'lets the owner remove a maintainer' do
      delete "/api/v1/projects/#{project.id}/memberships/#{maintainer_membership.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:no_content)
      expect(ProjectMembership.exists?(maintainer_membership.id)).to be(false)
    end

    it 'forbids a maintainer from removing members' do
      delete "/api/v1/projects/#{project.id}/memberships/#{maintainer_membership.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
      expect(ProjectMembership.exists?(maintainer_membership.id)).to be(true)
    end

    it 'does not let the owner be removed' do
      owner_membership = project.project_memberships.find_by(user: owner)

      delete "/api/v1/projects/#{project.id}/memberships/#{owner_membership.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:forbidden)
      expect(ProjectMembership.exists?(owner_membership.id)).to be(true)
    end
  end
end
