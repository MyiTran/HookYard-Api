require 'swagger_helper'

describe 'Session lifecycle' do
  let!(:user) { create(:user, password: 'password123') }

  def sign_in(user, password: 'password123')
    post '/api/v1/auth/sign_in', params: { user: { email: user.email, password: password } }, as: :json
    response.headers['Authorization']
  end

  describe 'JWT usage' do
    it 'issues a token on sign in that grants access to the profile endpoint' do
      token = sign_in(user)

      expect(response).to have_http_status(:ok)
      expect(token).to start_with('Bearer ')

      get '/api/v1/auth/profile', headers: { 'Authorization' => token }

      expect(response).to have_http_status(:ok)
      expect(json_response['email']).to eq(user.email)
    end

    it 'rejects a protected request without a token' do
      get '/api/v1/auth/profile'

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a protected request with an invalid token' do
      get '/api/v1/auth/profile', headers: { 'Authorization' => 'Bearer invalid.token.value' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'logout / revocation' do
    it 'stores the token in the allowlist after sign in' do
      sign_in(user)

      expect(AllowlistedJwt.count).to eq(1)
    end

    it 'revokes the token on sign out so it can no longer access protected endpoints' do
      token = sign_in(user)
      expect(AllowlistedJwt.count).to eq(1)

      delete '/api/v1/auth/sign_out', headers: { 'Authorization' => token }

      expect(response).to have_http_status(:no_content)
      expect(AllowlistedJwt.count).to eq(0)

      get '/api/v1/auth/profile', headers: { 'Authorization' => token }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects sign out without a token' do
      delete '/api/v1/auth/sign_out'

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
