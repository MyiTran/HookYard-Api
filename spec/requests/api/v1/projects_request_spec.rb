require 'swagger_helper'

describe 'Projects', type: :request do
  let(:owner) { create(:user) }
  let(:maintainer) { create(:user) }
  let(:outsider) { create(:user) }
  let(:project) do
    create(:project, :with_owner, owner: owner).tap do |created|
      create(:project_membership, project: created, user: maintainer, role: :maintainer)
    end
  end

  describe 'POST /api/v1/projects' do
    it 'creates the project and makes the creator its owner' do
      post '/api/v1/projects', params: { project: { name: 'Alpha' } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['name']).to eq('Alpha')
      expect(body['current_user_role']).to eq('owner')
      expect(Project.find(body['id']).project_memberships.pluck(:user_id, :role)).to eq([[owner.id, 'owner']])
    end

    it 'requires authentication' do
      post '/api/v1/projects', params: { project: { name: 'Alpha' } }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /api/v1/projects' do
    it 'only lists projects the current user belongs to' do
      project
      create(:project, :with_owner)

      get '/api/v1/projects', headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq([project.id])
    end

    it 'searches projects by name case-insensitively' do
      project.update!(name: 'Payment Gateway')
      create(:project, :with_owner, owner: maintainer, name: 'Internal Tool')

      get '/api/v1/projects', params: { search: 'payment' }, headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data'].map { |entry| entry['name'] }).to eq(['Payment Gateway'])
    end

    it 'returns an empty collection when no project matches the search' do
      project.update!(name: 'Payment Gateway')

      get '/api/v1/projects', params: { search: 'nginx' }, headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end

    it 'filters projects by the current user membership role' do
      project.update!(name: 'Maintained')
      create(:project, :with_owner, owner: maintainer, name: 'Owned')

      get '/api/v1/projects', params: { role: 'owner' }, headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['name'] }).to eq(['Owned'])
    end

    it 'filters by project membership role, not the global user role' do
      admin = create(:user).tap { |user| user.add_role(:admin) }
      create(:project, :with_owner).tap do |created|
        create(:project_membership, project: created, user: admin, role: :maintainer)
      end

      get '/api/v1/projects', params: { role: 'owner' }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end

    it 'orders projects by name ascending' do
      project.update!(name: 'Zeta')
      create(:project, :with_owner, owner: maintainer, name: 'Alpha')

      get '/api/v1/projects', params: { order: 'name_asc' }, headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['name'] }).to eq(%w[Alpha Zeta])
    end

    it 'combines search, role and order' do
      project.update!(name: 'Payments US')
      create(:project, :with_owner, owner: maintainer, name: 'Payments EU')
      create(:project, :with_owner, owner: maintainer, name: 'Payments APAC')
      create(:project, :with_owner, name: 'Payments Secret')

      get '/api/v1/projects',
          params: { search: 'payments', role: 'owner', order: 'name_asc' },
          headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['data'].map { |entry| entry['name'] }).to eq(['Payments APAC', 'Payments EU'])
    end

    it 'keeps current_user_role in the serialized collection' do
      project

      get '/api/v1/projects', headers: auth_headers(maintainer)

      expect(JSON.parse(response.body)['data'].first['current_user_role']).to eq('maintainer')
    end

    it 'never exposes a foreign project even when its name matches the search' do
      create(:project, :with_owner, name: 'Payments Secret')

      get '/api/v1/projects', params: { search: 'payments' }, headers: auth_headers(outsider)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end

    it 'does not leak foreign projects when filtering by role' do
      create(:project, :with_owner)

      get '/api/v1/projects', params: { role: 'owner' }, headers: auth_headers(outsider)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['data']).to eq([])
    end

    it 'requires authentication' do
      get '/api/v1/projects'

      expect(response).to have_http_status(:unauthorized)
    end

    describe 'pagination' do
      it 'returns the first page with pagination metadata by default' do
        create_list(:project, 3, :with_owner, owner: maintainer)

        get '/api/v1/projects', headers: auth_headers(maintainer)

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

      it 'returns the requested page' do
        create_list(:project, 5, :with_owner, owner: maintainer)

        get '/api/v1/projects', params: { page: { number: 2, size: 2 } }, headers: auth_headers(maintainer)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']).to include(
          'page_number' => 2,
          'page_size' => 2,
          'total_count' => 5,
          'prev_page' => 1,
          'next_page' => 3,
          'last_page' => 3
        )
      end

      it 'keeps a deterministic order across pages' do
        create_list(:project, 5, :with_owner, owner: maintainer)

        get '/api/v1/projects',
            params: { order: 'name_asc', page: { number: 1, size: 5 } },
            headers: auth_headers(maintainer)
        ordered_ids = JSON.parse(response.body)['data'].map { |entry| entry['id'] }

        get '/api/v1/projects',
            params: { order: 'name_asc', page: { number: 2, size: 2 } },
            headers: auth_headers(maintainer)

        expect(JSON.parse(response.body)['data'].map { |entry| entry['id'] }).to eq(ordered_ids[2, 2])
      end

      it 'applies search and role filters before pagination' do
        project.update!(name: 'Payments US')
        create(:project, :with_owner, owner: maintainer, name: 'Payments EU')
        create(:project, :with_owner, owner: maintainer, name: 'Internal Tool')
        create(:project, :with_owner, name: 'Payments Secret')

        get '/api/v1/projects',
            params: { search: 'payments', role: 'owner', page: { number: 1, size: 1 } },
            headers: auth_headers(maintainer)

        body = JSON.parse(response.body)
        expect(body['data'].map { |entry| entry['name'] }).to eq(['Payments EU'])
        expect(body['meta']).to include('total_count' => 1, 'last_page' => 1)
      end

      it 'counts only accessible projects in the pagination metadata' do
        create_list(:project, 2, :with_owner, owner: maintainer)
        create_list(:project, 3, :with_owner)

        get '/api/v1/projects', headers: auth_headers(maintainer)

        body = JSON.parse(response.body)
        expect(body['data'].size).to eq(2)
        expect(body['meta']['total_count']).to eq(2)
      end

      it 'caps the page size through the shared pagination concern' do
        get '/api/v1/projects', params: { page: { size: 500 } }, headers: auth_headers(maintainer)

        expect(JSON.parse(response.body)['meta']['page_size']).to eq(Pagination::MAX_PAGE_SIZE)
      end

      it 'returns an empty page past the last page' do
        create_list(:project, 3, :with_owner, owner: maintainer)

        get '/api/v1/projects', params: { page: { number: 99, size: 2 } }, headers: auth_headers(maintainer)

        body = JSON.parse(response.body)
        expect(body['data']).to be_empty
        expect(body['meta']).to include('page_number' => 99, 'last_page' => 2, 'prev_page' => 2)
      end

      it 'normalizes malformed pagination parameters instead of failing' do
        create_list(:project, 2, :with_owner, owner: maintainer)

        get '/api/v1/projects', params: { page: 'invalid' }, headers: auth_headers(maintainer)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['meta']).to include('page_number' => 1, 'page_size' => 25)
      end
    end
  end

  describe 'GET /api/v1/projects/:id' do
    it 'renders the current user role for a member' do
      get "/api/v1/projects/#{project.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['current_user_role']).to eq('maintainer')
    end

    it 'hides the project from a non-member' do
      get "/api/v1/projects/#{project.id}", headers: auth_headers(outsider)

      expect(response).to have_http_status(:not_found)
    end

    it 'cannot reach another project by UUID' do
      other_project = create(:project, :with_owner)

      get "/api/v1/projects/#{other_project.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /api/v1/projects/:id' do
    it 'lets the owner update' do
      patch "/api/v1/projects/#{project.id}", params: { project: { name: 'Renamed' } }, headers: auth_headers(owner), as: :json

      expect(response).to have_http_status(:ok)
      expect(project.reload.name).to eq('Renamed')
    end

    it 'forbids a maintainer' do
      patch "/api/v1/projects/#{project.id}", params: { project: { name: 'Renamed' } }, headers: auth_headers(maintainer), as: :json

      expect(response).to have_http_status(:forbidden)
      expect(project.reload.name).not_to eq('Renamed')
    end

    it 'hides the project from a non-member' do
      patch "/api/v1/projects/#{project.id}", params: { project: { name: 'Renamed' } }, headers: auth_headers(outsider), as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /api/v1/projects/:id' do
    it 'lets the owner delete' do
      delete "/api/v1/projects/#{project.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:no_content)
      expect(Project.exists?(project.id)).to be(false)
    end

    it 'forbids a maintainer' do
      delete "/api/v1/projects/#{project.id}", headers: auth_headers(maintainer)

      expect(response).to have_http_status(:forbidden)
      expect(Project.exists?(project.id)).to be(true)
    end
  end
end
