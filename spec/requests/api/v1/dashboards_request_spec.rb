require 'swagger_helper'

describe 'Dashboards' do
  path '/api/v1/dashboard' do
    get 'Show authenticated dashboard' do
      tags 'Dashboard'
      produces 'application/json'
      security [bearer_auth: {}]

      response '200', 'Support user' do
        schema type: :object, properties: {
          id: { type: :string, format: :uuid },
          email: { type: :string, format: :email },
          first_name: { type: :string },
          last_name: { type: :string },
          is_confirmed: { type: :boolean },
          role: { type: :string, nullable: true },
          avatar_url: { type: :string, format: :uri, nullable: true }
        }
        let(:support_user) { create(:user, password: 'password123').tap { |u| u.add_role(:support) } }
        let(:Authorization) { auth_header(support_user) }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['email']).to eq(support_user.email)
          expect(body['role']).to eq('support')
        end
      end

      response '200', 'Admin user' do
        schema type: :object, properties: {
          id: { type: :string, format: :uuid },
          email: { type: :string, format: :email },
          first_name: { type: :string },
          last_name: { type: :string },
          is_confirmed: { type: :boolean },
          role: { type: :string, nullable: true },
          avatar_url: { type: :string, format: :uri, nullable: true }
        }
        let(:admin_user) { create(:user, password: 'password123').tap { |u| u.add_role(:admin) } }
        let(:Authorization) { auth_header(admin_user) }

        run_test! do |response|
          expect(JSON.parse(response.body)['role']).to eq('admin')
        end
      end

      response '401', 'Missing token' do
        schema type: :object, properties: {
          message: { type: :string, example: 'You need to sign in or sign up before continuing.' },
          status: { type: :integer, example: 401 }
        }
        let(:Authorization) { nil }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
          expect(JSON.parse(response.body)['status']).to eq(401)
        end
      end

      response '401', 'Invalid token' do
        schema type: :object, properties: {
          message: { type: :string, example: 'You need to sign in or sign up before continuing.' },
          status: { type: :integer, example: 401 }
        }
        let(:Authorization) { 'Bearer invalid.token.value' }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
          expect(JSON.parse(response.body)['status']).to eq(401)
        end
      end
    end
  end
end
