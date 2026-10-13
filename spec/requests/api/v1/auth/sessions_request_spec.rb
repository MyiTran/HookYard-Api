require 'swagger_helper'

describe 'Sessions' do
  let!(:user) { create(:user, password: 'password123') }

  path '/api/v1/auth/sign_in' do
    post 'Sign in user' do
      tags 'Authentication'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :params, in: :body, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              email: { type: :string, format: :email },
              password: { type: :string }
            },
            required: %i[email password]
          }
        }
      }

      response '200', 'Success' do
        schema type: :object, properties: {
          id: { type: :string, format: :uuid },
          email: { type: :string, format: :email },
          first_name: { type: :string },
          last_name: { type: :string },
          is_confirmed: { type: :boolean },
          role: { type: :string, nullable: true },
          avatar_url: { type: :string, nullable: true }
        }
        header 'Authorization', schema: { type: :string, example: 'Bearer YOUR_TOKEN_HERE' }

        let(:params) { { user: { email: user.email, password: 'password123' } } }

        run_test! do |response|
          expect(response.headers['Authorization']).to start_with('Bearer ')

          body = JSON.parse(response.body)
          expect(body.keys).to match_array(%w[id email first_name last_name is_confirmed role avatar_url])
          expect(body).not_to include('password', 'encrypted_password', 'password_confirmation')
        end
      end

      response '401', 'Invalid password' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Invalid Email or password.' },
          status: { type: :integer, example: 401 }
        }
        let(:params) { { user: { email: user.email, password: 'incorrect' } } }

        run_test! do |response|
          expect(response.headers['Authorization']).to be_nil

          body = JSON.parse(response.body)
          expect(body['status']).to eq(401)
          expect(body['message']).to eq('Invalid Email or password.')
          expect(response.body.downcase).not_to include('token')
        end
      end

      response '401', 'Unknown email' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Invalid Email or password.' },
          status: { type: :integer, example: 401 }
        }
        let(:params) { { user: { email: 'nobody@example.com', password: 'password123' } } }

        run_test! do |response|
          expect(response.headers['Authorization']).to be_nil

          body = JSON.parse(response.body)
          expect(body['status']).to eq(401)
          expect(body['message']).to eq('Invalid Email or password.')
        end
      end

      response '401', 'Unconfirmed account' do
        schema type: :object, properties: {
          message: { type: :string, example: 'You have to confirm your email address before continuing.' },
          status: { type: :integer, example: 401 }
        }
        let(:unconfirmed_user) { create(:user, :need_confirmation, password: 'password123') }
        let(:params) { { user: { email: unconfirmed_user.email, password: 'password123' } } }

        run_test! do |response|
          expect(response.headers['Authorization']).to be_nil

          body = JSON.parse(response.body)
          expect(body['status']).to eq(401)
          expect(body['message']).to match(/confirm/i)
        end
      end
    end
  end

  path '/api/v1/auth/sign_out' do
    delete 'Sign out user' do
      tags 'Authentication'
      consumes 'application/json'
      produces 'application/json'
      security [bearer_auth: {}]

      response '204', 'Success' do
        let(:Authorization) { auth_header(user) }
        run_test!
      end

      response '401', 'Missing token' do
        schema type: :object, properties: {
          message: { type: :string, example: 'You are not authenticated' },
          status: { type: :integer, example: 401 }
        }
        let(:Authorization) { nil }

        run_test! do |response|
          expect(response).to have_http_status(:unauthorized)
          expect(JSON.parse(response.body)['status']).to eq(401)
        end
      end
    end
  end
end
