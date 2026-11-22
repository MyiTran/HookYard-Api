require 'swagger_helper'

describe 'Google sessions', type: :request do
  let(:claims) do
    {
      'sub' => 'google-subject',
      'email' => 'verified@example.com',
      'email_verified' => true
    }
  end
  let(:verifier) { instance_double(Authentication::GoogleTokenVerifier, verify: claims) }

  before do
    allow_any_instance_of(Api::V1::Auth::GoogleSessionsController).to receive(:google_token_verifier).and_return(verifier)
  end

  describe 'POST /api/v1/auth/google' do
    it 'returns the existing user serializer and a JWT for a verified Google identity' do
      user = create(:user, email: claims['email'])
      create(:user_identity, user:, uid: claims['sub'])

      post '/api/v1/auth/google', params: { credential: 'google-id-token' }, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.headers['Authorization']).to start_with('Bearer ')
      expect(json_response).to include('id' => user.id, 'email' => user.email)
      expect(json_response).not_to include('password', 'credential', 'encrypted_password')

      authorization = response.headers['Authorization']
      get '/api/v1/auth/profile', headers: { 'Authorization' => authorization }
      expect(response).to have_http_status(:ok)

      delete '/api/v1/auth/sign_out', headers: { 'Authorization' => authorization }
      expect(response).to have_http_status(:no_content)
    end

    it 'returns a generic unauthorized response when token verification fails' do
      allow(verifier).to receive(:verify).and_raise(ApiError::GoogleAuthenticationError.new)

      post '/api/v1/auth/google', params: { credential: 'forged-token' }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(json_response).to include('code' => 'google_authentication_failed')
    end

    it 'allows a newly created Google user to load an empty dashboard' do
      post '/api/v1/auth/google', params: { credential: 'google-id-token' }, as: :json

      get '/api/v1/dashboard', headers: { 'Authorization' => response.headers['Authorization'] }

      expect(response).to have_http_status(:ok)
      expect(json_response).to include(
        'workspace' => include('project_count' => 0),
        'delivery_health' => include('total' => 0, 'success_rate' => 0.0),
        'projects' => []
      )
    end

    it 'returns bad request when the credential is missing' do
      post '/api/v1/auth/google', params: {}, as: :json

      expect(response).to have_http_status(:bad_request)
    end

    it 'rate limits repeated requests from the same IP address' do
      20.times { post '/api/v1/auth/google', params: { credential: 'google-id-token' }, as: :json }

      post '/api/v1/auth/google', params: { credential: 'google-id-token' }, as: :json

      expect(response).to have_http_status(:too_many_requests)
      expect(json_response).to include('code' => 'google_authentication_rate_limited')
    end
  end
end
