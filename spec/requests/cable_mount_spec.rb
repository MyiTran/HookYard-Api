require 'rails_helper'

describe 'ActionCable mount', type: :request do
  describe 'GET /cable' do
    it 'routes into ActionCable instead of the API router' do
      get '/cable'

      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq('text/plain')
      expect(response.body).to eq('Page not found')
    end
  end

  describe 'routing' do
    it 'mounts the ActionCable server at /cable exactly once' do
      cable_apps = Rails.application.routes.routes
                          .select { |route| route.path.spec.to_s == '/cable' }
                          .map { |route| unwrap(route.app) }

      expect(cable_apps).not_to be_empty
      expect(cable_apps).to all(equal(ActionCable.server))
    end

    def unwrap(app)
      return app unless app.is_a?(ActionDispatch::Routing::Mapper::Constraints)

      app.instance_variable_get(:@app)
    end
  end
end
