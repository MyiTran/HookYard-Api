rate_limit_store =
  if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1')
    )
  end

Rails.application.config.x.google_authentication.rate_limit_store = rate_limit_store
