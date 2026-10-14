require 'swagger_helper'

describe 'Invitations', type: :request do
  let(:owner) { create(:user) }
  let(:recipient) { create(:user) }
  let(:other) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  describe 'GET /api/v1/invitations' do
    it 'returns only the current user pending invitations' do
      mine = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)
      create(:project_invitation, project: project, invited_by: owner, recipient: other)
      create(:project_invitation, project: project, invited_by: owner, recipient: recipient, status: :cancelled)

      get '/api/v1/invitations', headers: auth_headers(recipient)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([mine.id])
    end

    it 'requires authentication' do
      get '/api/v1/invitations'

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'PATCH /api/v1/invitations/:id/accept' do
    it 'lets the recipient accept and become a maintainer' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      patch "/api/v1/invitations/#{invitation.id}/accept", headers: auth_headers(recipient)

      expect(response).to have_http_status(:ok)
      expect(invitation.reload.status).to eq('accepted')
      expect(project.project_memberships.find_by(user: recipient).role).to eq('maintainer')
    end

    it 'does not let another user accept' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      patch "/api/v1/invitations/#{invitation.id}/accept", headers: auth_headers(other)

      expect(response).to have_http_status(:not_found)
      expect(invitation.reload).to be_pending
    end

    it 'cannot accept an already accepted invitation' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient, status: :accepted, accepted_at: Time.current)

      patch "/api/v1/invitations/#{invitation.id}/accept", headers: auth_headers(recipient)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(project.project_memberships.where(user: recipient).count).to eq(0)
    end

    it 'cannot accept a cancelled invitation' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient, status: :cancelled, cancelled_at: Time.current)

      patch "/api/v1/invitations/#{invitation.id}/accept", headers: auth_headers(recipient)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'creates exactly one membership when accepted twice' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      patch "/api/v1/invitations/#{invitation.id}/accept", headers: auth_headers(recipient)
      patch "/api/v1/invitations/#{invitation.id}/accept", headers: auth_headers(recipient)

      expect(project.project_memberships.where(user: recipient).count).to eq(1)
    end
  end

  describe 'PATCH /api/v1/invitations/:id/decline' do
    it 'lets the recipient decline without becoming a member' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      patch "/api/v1/invitations/#{invitation.id}/decline", headers: auth_headers(recipient)

      expect(response).to have_http_status(:ok)
      expect(invitation.reload).to be_declined
      expect(invitation.declined_at).to be_present
      expect(project.project_memberships.exists?(user: recipient)).to be(false)
    end

    it 'does not let another user decline' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient)

      patch "/api/v1/invitations/#{invitation.id}/decline", headers: auth_headers(other)

      expect(response).to have_http_status(:not_found)
      expect(invitation.reload).to be_pending
    end

    it 'cannot decline an already accepted invitation' do
      invitation = create(:project_invitation, project: project, invited_by: owner, recipient: recipient,
                                               status: :accepted, accepted_at: Time.current)

      patch "/api/v1/invitations/#{invitation.id}/decline", headers: auth_headers(recipient)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(invitation.reload).to be_accepted
    end
  end
end
