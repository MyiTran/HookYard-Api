require 'swagger_helper'

describe 'Cable tickets' do
  let(:user) { create(:user) }

  describe 'POST /api/v1/cable_ticket' do
    it 'requires authentication' do
      post '/api/v1/cable_ticket'

      expect(response).to have_http_status(:unauthorized)
    end

    it 'issues a ticket bound to the current user' do
      post '/api/v1/cable_ticket', headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      expect(json_response['token']).to be_present
      expect(json_response['expires_at']).to be_present
      expect(CableTicket.find_by(token: json_response['token']).user).to eq(user)
    end
  end
end
