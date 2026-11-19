class EndpointDiagnosisGuard
  LOCK_TTL_SECONDS = 60
  COOLDOWN_SECONDS = 30
  LOCK_RETRY_AFTER_SECONDS = 1
  RELEASE_SCRIPT = <<~LUA.freeze
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    end
    return 0
  LUA

  def initialize(redis: nil)
    @redis = redis || default_redis
  end

  def with_lock(endpoint:)
    acquire!(endpoint:)
    yield
  ensure
    release!
  end

  def mark_success!(endpoint:)
    redis.set(cooldown_key(endpoint), '1', ex: COOLDOWN_SECONDS)
  rescue Redis::BaseError
    nil
  end

  private

  attr_reader :redis

  def acquire!(endpoint:)
    if (cooldown_ttl = redis.ttl(cooldown_key(endpoint))).positive?
      raise cooldown_error(cooldown_ttl)
    end

    @lock_key = lock_key(endpoint)
    @lock_token = SecureRandom.hex(16)
    acquired = redis.set(@lock_key, @lock_token, nx: true, ex: LOCK_TTL_SECONDS)
    raise cooldown_error(LOCK_RETRY_AFTER_SECONDS) unless acquired
  end

  def release!
    redis.eval(RELEASE_SCRIPT, keys: [@lock_key], argv: [@lock_token]) if @lock_key
    @lock_key = nil
    @lock_token = nil
  rescue Redis::BaseError
    @lock_key = nil
    @lock_token = nil
  end

  def cooldown_error(retry_after)
    ApiError::DiagnosisCooldownError.new(retry_after: retry_after)
  end

  def lock_key(endpoint)
    "endpoint_diagnosis:lock:#{endpoint.id}"
  end

  def cooldown_key(endpoint)
    "endpoint_diagnosis:cooldown:#{endpoint.project_id}:#{endpoint.id}"
  end

  def default_redis
    Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1'))
  end
end
