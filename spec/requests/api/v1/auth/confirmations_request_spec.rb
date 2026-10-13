require 'swagger_helper'

describe 'Confirmations' do
  let!(:user) { create(:user, :need_confirmation) }

  path '/api/v1/auth/confirmation' do
    post 'Resend confirmation' do
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
          message: { type: :string, example: 'If your email address exists in our database, you will receive an email with instructions for how to confirm your email address in a few minutes' }
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

          post '/api/v1/auth/confirmation', params: { user: { email: user.email } }, as: :json
          known_message = JSON.parse(response.body)['message']

          expect(unknown_message).to be_present
          expect(unknown_message).to eq(known_message)
        end
      end
    end

    put 'Verify confirmation' do
      tags 'Authentication'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :params, in: :body, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              confirmation_token: { type: :string }
            },
            required: %i[confirmation_token]
          }
        }
      }

      response '200', 'Success' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Your account has been confirmed successfully.' }
        }
        let(:params) { { user: { confirmation_token: user.confirmation_token } } }

        run_test! do |response|
          expect(JSON.parse(response.body)['message']).to eq('Your account has been confirmed successfully.')
          expect(user.reload.confirmed?).to be(true)
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
                field: { type: :string, example: 'confirmation_token' },
                message: { type: :string, example: 'Confirmation token is invalid' }
              }
            }
          }
        }
        let(:params) { { user: { confirmation_token: 'invalid-token' } } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['message']).to eq('Unprocessable entity')
          expect(body['errors']).to contain_exactly(hash_including('field' => 'confirmation_token'))
        end
      end

      response '422', 'Blank token' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        let(:params) { { user: { confirmation_token: '' } } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['status']).to eq(422)
          expect(body['errors']).to contain_exactly(hash_including('field' => 'confirmation_token'))
        end
      end

      response '422', 'Already confirmed' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        let(:confirmed_user) { create(:user, :need_confirmation).tap(&:confirm) }
        let(:params) { { user: { confirmation_token: confirmed_user.confirmation_token } } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['status']).to eq(422)
          expect(body['errors']).to contain_exactly(hash_including('field' => 'email'))
        end
      end
    end
  end
end
