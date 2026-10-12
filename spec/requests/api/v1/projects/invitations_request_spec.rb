require 'swagger_helper'

describe 'Projects::Invitations' do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:recipient) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  describe 'POST /api/v1/projects/:project_id/invitations' do
    it 'invites an existing user' do
      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: recipient.email } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['status']).to eq('pending')
      expect(body['role']).to eq('maintainer')
      expect(ProjectInvitation.find(body['id']).recipient).to eq(recipient)
    end

    it 'forces the maintainer role and ignores a client supplied role' do
      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: recipient.email, role: 'owner' } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['role']).to eq('maintainer')
    end

    it 'rejects an unknown email' do
      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: 'nobody@example.com' } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects inviting yourself' do
      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: owner.email } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects inviting an existing member' do
      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: maintainer.email } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a duplicate pending invitation' do
      create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: recipient.email } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'forbids a maintainer from inviting' do
      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: recipient.email } }, headers: auth_headers(maintainer), as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'hides the project from a non-member' do
      post "/api/v1/projects/#{project.id}/invitations", params: { invitation: { email: recipient.email } }, headers: auth_headers(outsider), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/projects/:project_id/invitations' do
    it 'lets the owner list pending invitations' do
      create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      get "/api/v1/projects/#{project.id}/invitations", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].size).to eq(1)
    end

    it 'forbids a maintainer' do
      get "/api/v1/projects/#{project.id}/invitations", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'DELETE /api/v1/projects/:project_id/invitations/:id' do
    it 'lets the owner cancel a pending invitation' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      delete "/api/v1/projects/#{project.id}/invitations/#{invitation.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:no_content)
      expect(invitation.reload.status).to eq('cancelled')
    end

    it 'forbids a maintainer from cancelling' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      delete "/api/v1/projects/#{project.id}/invitations/#{invitation.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
      expect(invitation.reload.status).to eq('pending')
    end

    it 'cannot cancel an invitation belonging to another project' do
      other_project = create(:project, :with_owner, owner: owner)
      invitation = create(:project_invitation, project: other_project, invited_by: owner, recipient: recipient)

      delete "/api/v1/projects/#{project.id}/invitations/#{invitation.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:not_found)
      expect(invitation.reload.status).to eq('pending')
    end
  end
end
