require 'rails_helper'

describe EndpointDiagnosisGuard, type: :operation do
  let(:redis) { FakeRedis.new }
  let(:guard) { described_class.new(redis: redis) }
  let(:endpoint) { instance_double(Endpoint, id: 'endpoint-uuid', project_id: 'project-uuid') }

  describe '#with_lock' do
    it 'yields when there is no cooldown and the endpoint lock is free' do
      yielded = false

      guard.with_lock(endpoint: endpoint) { yielded = true }

      expect(yielded).to be(true)
      expect(redis.store).not_to have_key(lock_key)
    end

    it 'acquires the lock with an opaque token and expiry' do
      acquired_token = nil

      guard.with_lock(endpoint: endpoint) do
        acquired_token = redis.store[lock_key]
      end

      expect(acquired_token).not_to be_empty
      expect(acquired_token).not_to eq('1')
    end

    it 'raises a cooldown error with retry-after when the endpoint is cooling down' do
      redis.cooldowns[cooldown_key] = 12

      expect do
        guard.with_lock(endpoint: endpoint) { raise StandardError, 'must not run' }
      end.to raise_error(ApiError::DiagnosisCooldownError) do |error|
        expect(error.status).to eq(429)
        expect(error.code).to eq('diagnosis_rate_limited')
        expect(error.retry_after).to eq(12)
        expect(error.headers['Retry-After']).to eq('12')
      end
    end

    it 'raises a cooldown error when the endpoint lock is already held' do
      redis.store[lock_key] = 'other-owner-token'

      expect do
        guard.with_lock(endpoint: endpoint) { raise StandardError, 'must not run' }
      end.to raise_error(ApiError::DiagnosisCooldownError) do |error|
        expect(error.status).to eq(429)
        expect(error.retry_after).to eq(1)
        expect(error.headers['Retry-After']).to eq('1')
      end
    end

    it 'releases the in-flight lock when the block raises' do
      expect do
        guard.with_lock(endpoint: endpoint) { raise StandardError, 'unexpected failure' }
      end.to raise_error(StandardError, 'unexpected failure')

      expect(redis.store).not_to have_key(lock_key)
    end

    it 'does not delete a lock that was reacquired by another owner' do
      guard.with_lock(endpoint: endpoint) do
        redis.store[lock_key] = 'other-owner-token'
      end

      expect(redis.store[lock_key]).to eq('other-owner-token')
    end
  end

  describe '#mark_success!' do
    it 'starts a 30-second endpoint-wide cooldown' do
      guard.mark_success!(endpoint: endpoint)

      expect(redis.cooldowns[cooldown_key]).to eq(30)
    end

    it 'does not include the actor in the cooldown key' do
      guard.mark_success!(endpoint: endpoint)

      expect(cooldown_key).to eq("endpoint_diagnosis:cooldown:#{endpoint.project_id}:#{endpoint.id}")
      expect(redis.cooldowns).to have_key(cooldown_key)
    end

    it 'swallows Redis errors after a diagnosis has already been persisted' do
      allow(redis).to receive(:set).and_raise(Redis::BaseError, 'connection lost')

      expect { guard.mark_success!(endpoint: endpoint) }.not_to raise_error
    end
  end

  describe 'key scoping' do
    it 'uses a different lock key for a different endpoint' do
      other_endpoint = instance_double(Endpoint, id: 'other-endpoint-uuid', project_id: endpoint.project_id)
      acquired_keys = []

      guard.with_lock(endpoint: other_endpoint) do
        acquired_keys = redis.store.keys
      end

      expect(acquired_keys).to include("endpoint_diagnosis:lock:other-endpoint-uuid")
    end
  end

  def lock_key
    "endpoint_diagnosis:lock:#{endpoint.id}"
  end

  def cooldown_key
    "endpoint_diagnosis:cooldown:#{endpoint.project_id}:#{endpoint.id}"
  end
end
