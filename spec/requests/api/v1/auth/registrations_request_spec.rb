require 'swagger_helper'

describe 'Registrations' do
  path '/api/v1/auth/sign_up' do
    post 'Register user' do
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
              password: { type: :string },
              first_name: { type: :string },
              last_name: { type: :string }
            },
            required: %i[email password first_name last_name]
          }
        }
      }

      response '201', 'Success' do
        schema type: :object, properties: {
          id: { type: :string, format: :uuid },
          email: { type: :string, format: :email },
          first_name: { type: :string },
          last_name: { type: :string },
          is_confirmed: { type: :boolean },
          role: { type: :string, nullable: true },
          avatar_url: { type: :string, nullable: true }
        }
        let(:params) { { user: attributes_for(:user) } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.keys).to match_array(%w[id email first_name last_name is_confirmed role avatar_url])
          expect(body).not_to include('password', 'encrypted_password', 'password_confirmation')
          expect(body['role']).to eq('support')

          created_user = User.find(body['id'])
          expect(created_user.roles.pluck(:name)).to eq(['support'])
        end

        it 'does not assign a duplicate support role on a retried assignment' do
          post '/api/v1/auth/sign_up', params: { user: attributes_for(:user) }, as: :json
          created_user = User.find(JSON.parse(response.body)['id'])

          created_user.add_role(:support)

          expect(created_user.roles.reload.pluck(:name)).to eq(['support'])
          expect(Role.where(name: 'support').count).to eq(1)
        end
      end

      response '201', 'Role param cannot self-assign admin' do
        schema type: :object, properties: {
          id: { type: :string, format: :uuid },
          email: { type: :string, format: :email },
          first_name: { type: :string },
          last_name: { type: :string },
          is_confirmed: { type: :boolean },
          role: { type: :string, nullable: true },
          avatar_url: { type: :string, nullable: true }
        }
        let(:params) { { user: attributes_for(:user).merge(role: 'admin') } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['role']).to eq('support')

          created_user = User.find(body['id'])
          expect(created_user.has_role?(:admin)).to be(false)
          expect(created_user.roles.pluck(:name)).to eq(['support'])
        end
      end

      response '422', 'Missing first name' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: {
            type: :array,
            items: {
              type: :object,
              properties: {
                field: { type: :string, example: 'first_name' },
                message: { type: :string, example: "First name can't be blank" }
              }
            }
          }
        }
        let(:params) { { user: attributes_for(:user, first_name: nil) } }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['message']).to eq('Unprocessable entity')
          expect(body['errors']).to contain_exactly(hash_including('field' => 'first_name'))
        end
      end

      response '422', 'Missing last name' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        let(:params) { { user: attributes_for(:user, last_name: nil) } }

        run_test! do |response|
          expect(JSON.parse(response.body)['errors']).to contain_exactly(hash_including('field' => 'last_name'))
        end
      end

      response '422', 'Duplicate email' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        before do
          create(:user, email: 'dupe@example.com')
        end

        let(:params) { { user: attributes_for(:user, email: 'dupe@example.com') } }

        run_test! do |response|
          expect(JSON.parse(response.body)['errors']).to contain_exactly(hash_including('field' => 'email'))
        end
      end

      response '422', 'Invalid email' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        let(:params) { { user: attributes_for(:user, email: 'not-an-email') } }

        run_test! do |response|
          expect(JSON.parse(response.body)['errors']).to contain_exactly(hash_including('field' => 'email'))
        end
      end

      response '422', 'Password too short' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        let(:params) { { user: attributes_for(:user, password: 'short') } }

        run_test! do |response|
          expect(JSON.parse(response.body)['errors']).to contain_exactly(hash_including('field' => 'password'))
        end
      end

      response '422', 'Password confirmation mismatch' do
        schema type: :object, properties: {
          message: { type: :string, example: 'Unprocessable entity' },
          status: { type: :integer, example: 422 },
          errors: { type: :array, items: { type: :object, properties: { field: { type: :string }, message: { type: :string } } } }
        }
        let(:params) { { user: attributes_for(:user, password: 'password123', password_confirmation: 'different') } }

        run_test! do |response|
          expect(JSON.parse(response.body)['errors']).to contain_exactly(hash_including('field' => 'password_confirmation'))
        end
      end
    end
  end
end
