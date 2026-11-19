class FakeRedis
  attr_accessor :fail_cooldown
  attr_reader :store, :cooldowns

  def initialize
    @store = {}
    @cooldowns = {}
    @fail_cooldown = false
  end

  def ttl(key)
    cooldowns.fetch(key, -2)
  end

  def set(key, value, nx: false, ex: nil)
    raise Redis::BaseError, 'connection lost' if fail_cooldown && key.start_with?('endpoint_diagnosis:cooldown')

    if key.start_with?('endpoint_diagnosis:cooldown')
      cooldowns[key] = ex
      return 'OK'
    end

    return false if nx && store.key?(key)

    store[key] = value
    'OK'
  end

  def eval(_script, keys:, argv:)
    key = keys.first
    token = argv.first
    return 0 unless store[key] == token

    store.delete(key)
    1
  end

  def del(key)
    store.delete(key) ? 1 : 0
  end
end
