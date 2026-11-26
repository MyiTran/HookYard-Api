redis_url = ENV['REDIS_URL'].presence

raise KeyError, 'REDIS_URL must be configured in production for Google authentication rate limiting' if Rails.env.production? && redis_url.nil?

rate_limit_store =
  if Rails.env.test? || redis_url.nil?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(url: redis_url)
  end

Rails.application.config.x.google_authentication.rate_limit_store = rate_limit_store
