require 'swagger_helper'

describe 'Admin::Dashboards' do
  path '/api/v1/admin/dashboard' do
    get 'Show admin dashboard' do
      tags 'Admin'
      produces 'application/json'
      security [bearer_auth: {}]

      response '200', 'Admin can access the dashboard' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Welcome to Admin Dashboard' },
          stats: {
            type: :object,
            properties: {
              total_users: { type: :integer },
              total_projects: { type: :integer }
            }
          }
        }
        let(:admin) { create(:user, password: 'password123').tap { |u| u.add_role(:admin) } }
        let(:Authorization) { auth_header(admin) }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['message']).to eq('Welcome to Admin Dashboard')
          expect(body.dig('stats', 'total_users')).to be_a(Integer)
        end
      end

      response '403', 'Authenticated non-admin is forbidden' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Permission Denied' },
          status: { type: :integer, example: 403 }
        }
        let(:support_user) { create(:user, password: 'password123').tap { |u| u.add_role(:support) } }
        let(:Authorization) { auth_header(support_user) }

        run_test! do |response|
          expect(response).to have_http_status(:forbidden)
          expect(JSON.parse(response.body)['status']).to eq(403)
        end
      end

      response '401', 'Missing token' do
        schema type: :object, properties: {
          message: { type: :string, example: 'You are not authenticated' },
          status: { type: :integer, example: 401 }
        }
        let(:Authorization) { nil }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
        end
      end
    end
  end
end
