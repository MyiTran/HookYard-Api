require 'swagger_helper'

describe 'Admin::SupportAccounts', type: :request do
  let(:admin) { create(:user).tap { |user| user.add_role(:admin) } }
  let(:support_staff) { create(:user).tap { |user| user.add_role(:support) } }
  let!(:account) { create(:user, :pro, email: 'account@example.com') }

  describe 'GET /api/v1/admin/support_accounts' do
    context 'when unauthenticated' do
      it 'requires authentication' do
        get '/api/v1/admin/support_accounts'

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when the requester is a support account without the system admin role' do
      it 'denies access' do
        get '/api/v1/admin/support_accounts', headers: auth_headers(support_staff)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'when the requester is a system administrator' do
      before { support_staff }

      it 'returns paginated accounts with their roles and confirmation state' do
        get '/api/v1/admin/support_accounts', headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        entry = json_response['data'].find { |item| item['id'] == support_staff.id }
        expect(entry).to include(
          'email' => support_staff.email,
          'plan' => User::FREE_PLAN,
          'roles' => ['support'],
          'confirmed' => true,
          'sign_in_count' => support_staff.sign_in_count
        )
        expect(json_response['meta']).to include('page_number' => 1, 'page_size' => Pagy::DEFAULT[:limit])
      end

      it 'exposes only account metadata' do
        get '/api/v1/admin/support_accounts', headers: auth_headers(admin)

        expect(json_response['data'].first.keys).to contain_exactly(
          'id', 'email', 'first_name', 'last_name', 'name', 'plan', 'roles', 'confirmed', 'sign_in_count',
          'last_sign_in_at', 'created_at'
        )
      end

      it 'filters accounts by role' do
        get '/api/v1/admin/support_accounts', params: { role: 'support' }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to include(support_staff.id)
        expect(ids).not_to include(admin.id)
      end

      it 'searches accounts by email' do
        get '/api/v1/admin/support_accounts', params: { q: 'account@example.com' }, headers: auth_headers(admin)

        expect(json_response['data'].map { |item| item['id'] }).to eq([account.id])
      end

      it 'filters accounts by pro plan and excludes administrator accounts' do
        get '/api/v1/admin/support_accounts', params: { plan: 'pro' }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to include(account.id)
        expect(ids).not_to include(admin.id)
      end

      it 'filters accounts by free plan and excludes administrator accounts' do
        get '/api/v1/admin/support_accounts', params: { plan: 'free' }, headers: auth_headers(admin)

        ids = json_response['data'].map { |item| item['id'] }
        expect(ids).to include(support_staff.id)
        expect(ids).not_to include(admin.id)
        expect(ids).not_to include(account.id)
      end

      it 'ignores an invalid plan without exposing SQL errors' do
        get '/api/v1/admin/support_accounts',
            params: { plan: "'; DROP TABLE users;--" }, headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        expect(json_response['data']).not_to be_empty
      end

      it 'combines q, plan and pagination' do
        get '/api/v1/admin/support_accounts',
            params: { q: 'account@example.com', plan: 'pro', page: { size: 1 } }, headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        expect(json_response['data'].map { |item| item['id'] }).to eq([account.id])
        expect(json_response['meta']['page_size']).to eq(1)
      end

      it 'caps the requested page size' do
        get '/api/v1/admin/support_accounts', params: { page: { size: 500 } }, headers: auth_headers(admin)

        expect(json_response['meta']['page_size']).to eq(Pagination::MAX_PAGE_SIZE)
      end
    end
  end
end
