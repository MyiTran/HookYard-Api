require 'swagger_helper'

describe 'Endpoints', type: :request do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:other_project) { create(:project, :with_owner, owner: maintainer) }

  before { create(:project_membership, project: project, user: maintainer, role: :maintainer) }

  describe 'GET /api/v1/endpoints' do
    it 'lists endpoints from every accessible project' do
      owned = create(:endpoint, project: project)
      maintained = create(:endpoint, project: other_project)

      get '/api/v1/endpoints', headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to contain_exactly(owned.id, maintained.id)
    end

    it 'never exposes endpoints from projects the user does not belong to' do
      create(:endpoint, project: project)
      create(:endpoint)

      get '/api/v1/endpoints', headers: auth_headers(outsider)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end

    it 'excludes archived endpoints by default' do
      active = create(:endpoint, project: project)
      create(:endpoint, project: project, archived_at: Time.current)

      get '/api/v1/endpoints', headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([active.id])
    end

    it 'returns only archived endpoints when archived is true' do
      create(:endpoint, project: project)
      archived = create(:endpoint, project: project, archived_at: Time.current)

      get '/api/v1/endpoints', params: { archived: 'true' }, headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([archived.id])
    end

    it 'searches by name' do
      create(:endpoint, project: project, name: 'Payment Webhook')
      create(:endpoint, project: project, name: 'Billing Webhook')

      get '/api/v1/endpoints', params: { q: 'payment' }, headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['name'] }).to eq(['Payment Webhook'])
    end

    it 'searches by url' do
      create(:endpoint, project: project, name: 'Hook', url: 'https://payments.example.com/hooks')
      create(:endpoint, project: project, name: 'Other', url: 'https://billing.example.com/hooks')

      get '/api/v1/endpoints', params: { q: 'payments.example' }, headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['url'] }).to eq(['https://payments.example.com/hooks'])
    end

    it 'filters by project' do
      owned = create(:endpoint, project: project)
      create(:endpoint, project: other_project)

      get '/api/v1/endpoints', params: { project_id: project.id }, headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([owned.id])
    end

    it 'filters by active endpoints' do
      active = create(:endpoint, project: project, active: true)
      create(:endpoint, project: project, active: false)

      get '/api/v1/endpoints', params: { active: 'true' }, headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([active.id])
    end

    it 'filters by inactive endpoints' do
      create(:endpoint, project: project, active: true)
      inactive = create(:endpoint, project: project, active: false)

      get '/api/v1/endpoints', params: { active: 'false' }, headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([inactive.id])
    end

    it 'orders by name ascending' do
      create(:endpoint, project: project, name: 'Zulu')
      create(:endpoint, project: project, name: 'Alpha')

      get '/api/v1/endpoints', params: { order: 'name_asc' }, headers: auth_headers(owner)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['name'] }).to eq(%w[Alpha Zulu])
    end

    it 'never exposes the raw signing secret' do
      create(:endpoint, project: project)

      get '/api/v1/endpoints', headers: auth_headers(owner)

      entry = JSON.parse(response.body)['data'].first
      expect(entry).not_to have_key('signing_secret')
      expect(entry['has_signing_secret']).to be(true)
      expect(entry['signing_secret_version']).to eq(1)
    end

    it 'requires authentication' do
      get '/api/v1/endpoints'

      expect(response).to have_http_status(:unauthorized)
    end

    describe 'pagination' do
      it 'returns the first page with pagination metadata' do
        create_list(:endpoint, 3, project: project)

        get '/api/v1/endpoints', headers: auth_headers(owner)

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

      it 'returns the requested page of records with correct metadata' do
        create_list(:endpoint, 5, project: project)

        get '/api/v1/endpoints', params: { page: { number: 2, size: 2 } }, headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']['page_number']).to eq(2)
        expect(body['meta']['page_size']).to eq(2)
        expect(body['meta']['total_count']).to eq(5)
        expect(body['meta']['last_page']).to eq(3)
      end

      it 'keeps a deterministic ordering across pages' do
        create_list(:endpoint, 5, project: project)

        get '/api/v1/endpoints', params: { page: { number: 1, size: 5 } }, headers: auth_headers(owner)
        ordered_ids = JSON.parse(response.body)['data'].map { |entry| entry['id'] }

        get '/api/v1/endpoints', params: { page: { number: 1, size: 2 } }, headers: auth_headers(owner)
        first_page = JSON.parse(response.body)['data'].map { |entry| entry['id'] }

        get '/api/v1/endpoints', params: { page: { number: 2, size: 2 } }, headers: auth_headers(owner)
        second_page = JSON.parse(response.body)['data'].map { |entry| entry['id'] }

        expect(first_page + second_page).to eq(ordered_ids.first(4))
      end

      it 'applies the search filter before pagination' do
        create_list(:endpoint, 3, project: project, name: 'Payment hook', url: 'https://payments.example.com/hooks')
        create_list(:endpoint, 2, project: project, name: 'Billing hook', url: 'https://billing.example.com/hooks')

        get '/api/v1/endpoints', params: { q: 'payment', page: { number: 1, size: 2 } }, headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']['total_count']).to eq(3)
        expect(body['data'].map { |entry| entry['name'] }).to all(eq('Payment hook'))
      end

      it 'applies the project filter before pagination' do
        create_list(:endpoint, 3, project: project)
        create_list(:endpoint, 4, project: other_project)

        get '/api/v1/endpoints', params: { project_id: project.id, page: { number: 1, size: 2 } }, headers: auth_headers(maintainer)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']['total_count']).to eq(3)
      end

      it 'applies the archive filter before pagination' do
        create_list(:endpoint, 3, project: project, archived_at: Time.current)
        create_list(:endpoint, 2, project: project)

        get '/api/v1/endpoints', params: { archived: 'true', page: { number: 1, size: 2 } }, headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']['total_count']).to eq(3)
      end

      it 'does not count endpoints from inaccessible projects' do
        create_list(:endpoint, 4, project: other_project)
        create_list(:endpoint, 2, project: project)

        get '/api/v1/endpoints', params: { page: { number: 1, size: 10 } }, headers: auth_headers(owner)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']['total_count']).to eq(2)
      end

      it 'returns the records that belong to the requested page' do
        create_list(:endpoint, 5, project: project)

        get '/api/v1/endpoints', params: { page: { number: 1, size: 5 } }, headers: auth_headers(owner)
        ordered_ids = JSON.parse(response.body)['data'].map { |entry| entry['id'] }

        get '/api/v1/endpoints', params: { page: { number: 2, size: 2 } }, headers: auth_headers(owner)

        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq(ordered_ids[2, 2])
      end

      it 'caps the requested page size at a safe maximum' do
        create_list(:endpoint, 3, project: project)

        get '/api/v1/endpoints', params: { page: { number: 1, size: 1000 } }, headers: auth_headers(owner)

        expect(JSON.parse(response.body)['meta']['page_size']).to eq(Pagination::MAX_PAGE_SIZE)
      end
    end
  end
end
