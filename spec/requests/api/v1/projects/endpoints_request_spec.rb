require 'swagger_helper'

describe 'Projects::Endpoints', type: :request do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  describe 'GET /api/v1/projects/:project_id/endpoints' do
    it 'lets a member list the project endpoints' do
      endpoint = create(:endpoint, project: project)

      get "/api/v1/projects/#{project.id}/endpoints", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([endpoint.id])
    end

    it 'only lists endpoints from the requested project' do
      create(:endpoint, project: project)
      create(:endpoint)

      get "/api/v1/projects/#{project.id}/endpoints", headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['data'].size).to eq(1)
    end

    it 'excludes archived endpoints' do
      create(:endpoint, project: project)
      create(:endpoint, project: project, archived_at: Time.current)

      get "/api/v1/projects/#{project.id}/endpoints", headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].size).to eq(1)
    end

    it 'never exposes the raw signing secret' do
      create(:endpoint, project: project)

      get "/api/v1/projects/#{project.id}/endpoints", headers: auth_headers(maintainer)

      entry = JSON.parse(response.body)['data'].first
      expect(entry).not_to have_key('signing_secret')
      expect(entry['has_signing_secret']).to be(true)
      expect(entry['signing_secret_version']).to eq(1)
    end

    it 'hides the project from a non-member' do
      get "/api/v1/projects/#{project.id}/endpoints", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end

    describe 'pagination' do
      it 'returns the first page with pagination metadata' do
        create_list(:endpoint, 3, project: project)

        get "/api/v1/projects/#{project.id}/endpoints", headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(3)
        expect(body['meta']).to eq(
          'page_number' => 1,
          'page_size' => 25,
          'total_count' => 3,
          'prev_page' => nil,
          'next_page' => nil,
          'last_page' => 1
        )
      end

      it 'returns the requested page of project endpoints' do
        create_list(:endpoint, 3, project: project)

        get "/api/v1/projects/#{project.id}/endpoints", params: { page: { number: 2, size: 2 } }, headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(1)
        expect(body['meta']['page_number']).to eq(2)
        expect(body['meta']['total_count']).to eq(3)
        expect(body['meta']['last_page']).to eq(2)
      end

      it 'keeps a deterministic ordering across pages' do
        create_list(:endpoint, 5, project: project)

        get "/api/v1/projects/#{project.id}/endpoints", params: { page: { number: 1, size: 5 } }, headers: auth_headers(owner)
        ordered_ids = JSON.parse(response.body)['data'].map { |entry| entry['id'] }

        get "/api/v1/projects/#{project.id}/endpoints", params: { page: { number: 2, size: 2 } }, headers: auth_headers(owner)
        second_page = JSON.parse(response.body)['data'].map { |entry| entry['id'] }

        expect(second_page).to eq(ordered_ids[2, 2])
      end

      it 'applies the search filter before pagination' do
        create_list(:endpoint, 3, project: project, name: 'Payment hook', url: 'https://payments.example.com/hooks')
        create_list(:endpoint, 2, project: project, name: 'Billing hook', url: 'https://billing.example.com/hooks')

        get "/api/v1/projects/#{project.id}/endpoints", params: { q: 'payment', page: { number: 1, size: 2 } }, headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']['total_count']).to eq(3)
      end

      it 'falls back to the default page when the page parameter is not nested' do
        create_list(:endpoint, 2, project: project)

        get "/api/v1/projects/#{project.id}/endpoints", params: { page: '2' }, headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['meta']).to include('page_number' => 1, 'page_size' => 25)
      end

      it 'falls back to the default page when the page parameter is an array' do
        create_list(:endpoint, 2, project: project)

        get "/api/v1/projects/#{project.id}/endpoints", params: { page: ['2'] }, headers: auth_headers(owner)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['meta']).to include('page_number' => 1, 'page_size' => 25)
      end

      it 'normalizes nested array or hash page values' do
        create_list(:endpoint, 2, project: project)

        get "/api/v1/projects/#{project.id}/endpoints",
            params: { page: { number: [2], size: { value: 5 } } },
            headers: auth_headers(owner)

        expect(JSON.parse(response.body)['meta']).to include('page_number' => 1, 'page_size' => 25)
      end

      it 'falls back to page 1 for non-positive page numbers' do
        create_list(:endpoint, 2, project: project)

        [0, -1].each do |number|
          get "/api/v1/projects/#{project.id}/endpoints",
              params: { page: { number: number } },
              headers: auth_headers(owner)

          expect(JSON.parse(response.body)['meta']['page_number']).to eq(1),
                                                                     "expected page number #{number} to fall back to 1"
        end
      end

      it 'does not partially accept a non-numeric page number' do
        create_list(:endpoint, 2, project: project)

        get "/api/v1/projects/#{project.id}/endpoints",
            params: { page: { number: '2abc' } },
            headers: auth_headers(owner)

        expect(JSON.parse(response.body)['meta']['page_number']).to eq(1)
      end

      it 'falls back to the default size for an invalid size' do
        create_list(:endpoint, 2, project: project)

        get "/api/v1/projects/#{project.id}/endpoints",
            params: { page: { size: ['10'] } },
            headers: auth_headers(owner)

        expect(JSON.parse(response.body)['meta']['page_size']).to eq(25)
      end

      it 'caps the page size at the maximum' do
        create_list(:endpoint, 2, project: project)

        get "/api/v1/projects/#{project.id}/endpoints",
            params: { page: { size: 500 } },
            headers: auth_headers(owner)

        expect(JSON.parse(response.body)['meta']['page_size']).to eq(100)
      end

      it 'returns an empty page past the last page' do
        create_list(:endpoint, 3, project: project)

        get "/api/v1/projects/#{project.id}/endpoints",
            params: { page: { number: 99, size: 2 } },
            headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data']).to be_empty
        expect(body['meta']).to include('page_number' => 99, 'last_page' => 2, 'prev_page' => 2)
      end
    end
  end

  describe 'POST /api/v1/projects/:project_id/endpoints' do
    it 'creates an endpoint for the owner and returns a one-time signing secret' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks', description: 'Payments' } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['name']).to eq('Billing')
      expect(body['url']).to eq('https://example.com/hooks')
      expect(body['description']).to eq('Payments')
      expect(body['active']).to be(true)
      expect(body['event_types']).to eq([])
      expect(body['archived_at']).to be_nil
      expect(body['project']).to eq({ 'id' => project.id, 'name' => project.name })
      expect(body['signing_secret']).to be_present
      expect(body['has_signing_secret']).to be(true)
      expect(body['signing_secret_version']).to eq(1)

      endpoint = Endpoint.find(body['id'])
      expect(endpoint.current_signing_secret.version).to eq(1)
      expect(endpoint.current_signing_secret.ciphertext_for(:secret)).not_to include(body['signing_secret'])
    end

    it "subscribes to every event with '*'" do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks', event_types: ['*'] } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['event_types']).to eq(['*'])
    end

    it 'subscribes to multiple specific event types' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks', event_types: %w[order.created order.updated] } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['event_types']).to contain_exactly('order.created', 'order.updated')
    end

    it 'rejects duplicate event types' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks', event_types: %w[order.created order.created] } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(project.endpoints.count).to eq(0)
    end

    it "rejects mixing '*' with specific event types" do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks', event_types: ['*', 'order.created'] } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a missing name' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: '', url: 'https://example.com/hooks' } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects an invalid url' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'not-a-url' } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects a non-public url' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'http://127.0.0.1:3000/hooks' } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['errors']).to contain_exactly(hash_including('field' => 'url'))
      expect(project.endpoints.count).to eq(0)
    end

    it 'creates an inactive endpoint when active is false' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks', active: false } },
           headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['active']).to be(false)
    end

    it 'forbids a maintainer' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks' } },
           headers: auth_headers(maintainer), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(project.endpoints.count).to eq(0)
    end

    it 'hides the project from a non-member' do
      post "/api/v1/projects/#{project.id}/endpoints",
           params: { endpoint: { name: 'Billing', url: 'https://example.com/hooks' } },
           headers: auth_headers(outsider), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'GET /api/v1/projects/:project_id/endpoints/:id' do
    it 'lets a member view an endpoint without exposing the signing secret' do
      endpoint = create(:endpoint, project: project)

      get "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['id']).to eq(endpoint.id)
      expect(JSON.parse(response.body)).not_to have_key('signing_secret')
      expect(JSON.parse(response.body)['has_signing_secret']).to be(true)
      expect(JSON.parse(response.body)['signing_secret_version']).to eq(1)
    end

    it 'still reads an archived endpoint' do
      endpoint = create(:endpoint, project: project, archived_at: Time.current)

      get "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['archived_at']).to be_present
    end

    it 'does not expose an endpoint from another project' do
      other_project = create(:project, :with_owner, owner: owner)
      endpoint = create(:endpoint, project: other_project)

      get "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:not_found)
    end

    it 'hides the project from a non-member' do
      endpoint = create(:endpoint, project: project)

      get "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /api/v1/projects/:project_id/endpoints/:id' do
    it 'lets the owner update an endpoint and its subscriptions' do
      endpoint = create(:endpoint, project: project)

      patch "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}",
            params: { endpoint: { name: 'Renamed', active: false, event_types: %w[order.created order.updated] } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(endpoint.reload.name).to eq('Renamed')
      expect(endpoint.active).to be(false)
      expect(endpoint.event_types).to contain_exactly('order.created', 'order.updated')
    end

    it 'reactivates an inactive endpoint' do
      endpoint = create(:endpoint, project: project, active: false)

      patch "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}",
            params: { endpoint: { active: true } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(endpoint.reload.active).to be(true)
    end

    it 'rejects a non-public url' do
      endpoint = create(:endpoint, project: project)
      original_url = endpoint.url

      patch "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}",
            params: { endpoint: { url: 'http://169.254.169.254/latest/meta-data' } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(endpoint.reload.url).to eq(original_url)
    end

    it 'forbids a maintainer' do
      endpoint = create(:endpoint, project: project)

      patch "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}",
            params: { endpoint: { name: 'Renamed' } },
            headers: auth_headers(maintainer), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(endpoint.reload.name).not_to eq('Renamed')
    end

    it 'cannot update an endpoint from another project' do
      other_project = create(:project, :with_owner, owner: owner)
      endpoint = create(:endpoint, project: other_project)

      patch "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}",
            params: { endpoint: { name: 'Renamed' } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:not_found)
      expect(endpoint.reload.name).not_to eq('Renamed')
    end

    it 'forbids updating an archived endpoint' do
      endpoint = create(:endpoint, project: project, archived_at: Time.current)

      patch "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}",
            params: { endpoint: { name: 'Renamed' } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(endpoint.reload.name).not_to eq('Renamed')
    end

    it 'forbids changing the subscription of an archived endpoint' do
      endpoint = create(:endpoint, project: project, archived_at: Time.current)

      patch "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}",
            params: { endpoint: { event_types: ['*'] } },
            headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(endpoint.reload.event_types).to eq([])
    end
  end

  describe 'DELETE /api/v1/projects/:project_id/endpoints/:id' do
    it 'archives the endpoint instead of destroying it' do
      endpoint = create(:endpoint, project: project)

      delete "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:no_content)
      expect(Endpoint.exists?(endpoint.id)).to be(true)
      expect(endpoint.reload).to be_archived
    end

    it 'forbids a maintainer' do
      endpoint = create(:endpoint, project: project)

      delete "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
      expect(endpoint.reload).not_to be_archived
    end

    it 'cannot archive an endpoint from another project' do
      other_project = create(:project, :with_owner, owner: owner)
      endpoint = create(:endpoint, project: other_project)

      delete "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:not_found)
      expect(endpoint.reload).not_to be_archived
    end
  end

  describe 'POST /api/v1/projects/:project_id/endpoints/:id/rotate_signing_secret' do
    it 'returns a new one-time signing secret for the owner' do
      endpoint = create(:endpoint, project: project)
      original = endpoint.current_signing_secret.secret

      post "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/rotate_signing_secret", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['signing_secret']).to be_present
      expect(body['signing_secret']).not_to eq(original)
      expect(body['signing_secret_version']).to eq(2)
      expect(endpoint.reload.endpoint_signing_secrets.count).to eq(2)
    end

    it 'forbids a maintainer' do
      endpoint = create(:endpoint, project: project)

      post "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/rotate_signing_secret", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
      expect(endpoint.reload.endpoint_signing_secrets.count).to eq(1)
    end

    it 'forbids rotating the secret of an archived endpoint' do
      endpoint = create(:endpoint, project: project, archived_at: Time.current)

      post "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/rotate_signing_secret", headers: auth_headers(owner)

      expect(response).to have_http_status(:forbidden)
      expect(endpoint.reload.endpoint_signing_secrets.count).to eq(1)
    end

    it 'hides the project from a non-member' do
      endpoint = create(:endpoint, project: project)

      post "/api/v1/projects/#{project.id}/endpoints/#{endpoint.id}/rotate_signing_secret", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'signing secret logging protection' do
    it 'filters the raw secret from logged parameters' do
      filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

      expect(filter.filter(signing_secret: 'raw-secret-value')[:signing_secret]).to eq('[FILTERED]')
      expect(filter.filter(secret: 'raw-secret-value')[:secret]).to eq('[FILTERED]')
    end
  end
end
