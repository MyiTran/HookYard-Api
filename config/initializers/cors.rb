# Be sure to restart your server when you modify this file.

# Avoid CORS issues when API is called from the frontend app.
# Handle Cross-Origin Resource Sharing (CORS) in order to accept cross-origin AJAX requests.

# Read more: https://github.com/cyu/rack-cors

frontend_url = ENV['FRONTEND_URL'].presence

if Rails.env.production? && frontend_url.blank?
  raise KeyError, 'FRONTEND_URL must be set in production'
end

allowed_origins = [frontend_url]
unless Rails.env.production?
  allowed_origins.concat([
    %r{\Ahttp://localhost(?::\d+)?\z},
    %r{\Ahttp://127\.0\.0\.1(?::\d+)?\z}
  ])
end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*allowed_origins.compact)
    resource '*', headers: :any,
                  expose: ['Authorization'],
                  methods: [:get, :post, :put, :patch, :delete, :options, :head]
  end
end
