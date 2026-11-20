require 'swagger_helper'

describe 'Admin::Dashboards' do
  path '/api/v1/admin/dashboard' do
    get 'Show admin overview' do
      tags 'Admin'
      produces 'application/json'
      security [bearer_auth: {}]

      response '200', 'Admin can access the overview' do
        schema type: :object, properties: {
          generated_at: { type: :string, format: 'date-time' },
          accounts: {
            type: :object,
            properties: {
              total: { type: :integer },
              admins: { type: :integer },
              support: { type: :integer },
              unconfirmed: { type: :integer }
            }
          },
          projects: {
            type: :object,
            properties: {
              total: { type: :integer }
            }
          },
          endpoints: {
            type: :object,
            properties: {
              active: { type: :integer },
              circuit_open: { type: :integer },
              disabled: { type: :integer },
              queued_messages: { type: :integer }
            }
          },
          deliveries: {
            type: :object,
            properties: {
              window_days: { type: :integer },
              total_attempts: { type: :integer },
              succeeded_attempts: { type: :integer },
              failed_attempts: { type: :integer },
              success_rate: { type: :number },
              in_flight: { type: :integer },
              held: { type: :integer },
              retries_due: { type: :integer }
            }
          }
        }
        let(:admin) { create(:user, password: 'password123').tap { |user| user.add_role(:admin) } }
        let(:Authorization) { auth_header(admin) }

        run_test! do |response|
          body = JSON.parse(response.body)

          expect(body['generated_at']).to be_present
          expect(body['accounts']['admins']).to be >= 1
          expect(body['projects']['total']).to be >= 0
          expect(body['endpoints'].keys).to contain_exactly('active', 'circuit_open', 'disabled', 'queued_messages')
          expect(body['deliveries']['window_days']).to eq(30)
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
