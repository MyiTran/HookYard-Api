require 'swagger_helper'

describe 'Passwords' do
  let!(:user) { create(:user, password: 'oldpassword123') }

  path '/api/v1/auth/password' do
    post 'Request reset password' do
      tags 'Authentication'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :params, in: :body, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              email: { type: :string, format: :email }
            },
            required: %i[email]
          }
        }
      }

      response '200', 'Success' do
        schema type: :object, properties: {
          message: { type: :string, example: 'If your email address exists in our database, you will receive a password recovery link at your email address in a few minutes.' }
        }
        let(:params) { { user: { email: user.email } } }
        run_test!
      end

      response '200', 'Unknown email does not leak account existence' do
        schema type: :object, properties: {
          message: { type: :string }
        }
        let(:params) { { user: { email: 'nobody@example.com' } } }

        run_test! do |response|
          unknown_message = JSON.parse(response.body)['message']

          post '/api/v1/auth/password', params: { user: { email: user.email } }, as: :json
          known_message = JSON.parse(response.body)['message']

          expect(unknown_message).to be_present
          expect(unknown_message).to eq(known_message)
        end
      end
    end

    put 'Change password' do
      tags 'Authentication'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :params, in: :body, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              password: { type: :string },
              reset_password_token: { type: :string }
            },
            required: %i[password reset_password_token]
          }
        }
      }

      before do
        @token = user.send(:set_reset_password_token)
      end

      response '200', 'Success' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Your password has been changed successfully' }
        }
        let(:params) { { user: { password: 'password123', reset_password_token: @token } } }

        run_test! do |response|
          expect(JSON.parse(response.body)['message']).to be_present
        end

        it 'allows signing in with the new password' do
          put '/api/v1/auth/password', params: { user: { password: 'password123', reset_password_token: @token } }, as: :json
          post '/api/v1/auth/sign_in', params: { user: { email: user.email, password: 'password123' } }, as: :json

          expect(response).to have_http_status(:ok)
        end
      end

      response '422', 'Invalid token' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: {
            type: :array,
            items: {
              type: :object,
              properties: {
                field: { type: :string, example: 'reset_password_token' },
                message: { type: :string, example: 'Reset password token is invalid' }
              }
            }
          }
        }
        let(:params) { { user: { password: 'password123', reset_password_token: 'invalid-token' } } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['message']).to eq('Unprocessable entity')
          expect(body['errors']).to contain_exactly(hash_including('field' => 'reset_password_token'))
        end
      end

      response '422', 'Password confirmation mismatch' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        let(:params) { { user: { password: 'password123', password_confirmation: 'different', reset_password_token: @token } } }

        run_test! do |response|
          expect(JSON.parse(response.body)['errors']).to contain_exactly(hash_including('field' => 'password_confirmation'))
        end
      end
    end
  end
end
