Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1') }

  schedule_path = Rails.root.join('config/schedule.yml')
  Sidekiq::Cron::Job.load_from_hash(YAML.load_file(schedule_path)) if schedule_path.exist?
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1') }
end
