require 'sidekiq/web'
require 'sidekiq/cron/web'

sidekiq_web_username = ENV['SIDEKIQ_WEB_USERNAME']
sidekiq_web_password = ENV['SIDEKIQ_WEB_PASSWORD']

if Rails.env.production? && (sidekiq_web_username.blank? || sidekiq_web_password.blank?)
  raise KeyError, 'SIDEKIQ_WEB_USERNAME and SIDEKIQ_WEB_PASSWORD must be set in production'
end

if sidekiq_web_username.present? && sidekiq_web_password.present?
  Sidekiq::Web.use Rack::Auth::Basic do |username, password|
    ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(username), Digest::SHA256.hexdigest(sidekiq_web_username)) &
      ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.hexdigest(password), Digest::SHA256.hexdigest(sidekiq_web_password))
  end
end
