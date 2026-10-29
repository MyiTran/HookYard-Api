require 'rails_helper'

describe Events::Ingest, type: :operation do
  let(:project) { create(:project) }
  let(:account) { project.billing_owner }
  let!(:endpoint) { create(:endpoint, project: project) }
  let(:attributes) do
    {
      event_type: 'order.created',
      payload: { 'order_id' => SecureRandom.uuid },
      idempotency_key: SecureRandom.uuid
    }
  end

  before { endpoint.update!(event_types: [Endpoint::WILDCARD_EVENT_TYPE]) }

  describe '.call' do
    it 'persists the event with its messages and enqueues delivery' do
      expect { @result = described_class.call(project: project, attributes: attributes) }
        .to have_enqueued_job(Messages::DeliverJob)

      expect(@result.created).to be(true)
      expect(@result.event).to be_persisted
      expect(@result.messages_count).to eq(1)
    end

    it 'keeps the committed event and messages waiting when enqueueing fails' do
      allow(Messages::DeliverJob).to receive(:perform_later).and_raise(StandardError, 'redis unavailable')
      allow(Rails.logger).to receive(:error).and_call_original

      result = described_class.call(project: project, attributes: attributes)

      expect(result.event.reload).to be_persisted
      expect(result.event.messages.pending.count).to eq(1)
      expect(Rails.logger).to have_received(:error).with(/enqueue failed for message/)
    end

    it 'increments the endpoint queue count for every created message' do
      described_class.call(project: project, attributes: attributes)

      expect(endpoint.reload.queued_message_count).to eq(1)
    end

    it 'does not count a duplicate event twice' do
      described_class.call(project: project, attributes: attributes)
      described_class.call(project: project, attributes: attributes)

      expect(endpoint.reload.queued_message_count).to eq(1)
      expect(project.events.count).to eq(1)
    end

    it 'keeps queued messages available to a paused endpoint only through manual action' do
      endpoint.update!(active: false)

      result = described_class.call(project: project, attributes: attributes)

      expect(result.messages_count).to eq(0)
      expect(endpoint.reload.queued_message_count).to eq(0)
      expect(endpoint).to be_enabled
    end

    context 'when the endpoint circuit is open' do
      before do
        endpoint.update!(
          circuit_state: 'circuit_open',
          circuit_failure_count: 5,
          circuit_opened_at: Time.current,
          circuit_next_probe_at: Time.current
        )
      end

      it 'accepts the message but holds it without enqueueing delivery' do
        result = nil

        expect { result = described_class.call(project: project, attributes: attributes) }
          .not_to have_enqueued_job(Messages::DeliverJob)

        message = result.event.messages.first
        expect(result.messages_count).to eq(1)
        expect(message).to be_held
        expect(message.hold_reason).to eq('endpoint_circuit_open')
        expect(endpoint.reload.queued_message_count).to eq(1)
      end
    end

    context 'when the endpoint circuit is disabled' do
      before { endpoint.update!(circuit_state: 'disabled', circuit_failure_count: 5) }

      it 'accepts the message but holds it for the disabled endpoint' do
        expect { described_class.call(project: project, attributes: attributes) }
          .not_to have_enqueued_job(Messages::DeliverJob)

        message = project.events.last.messages.first
        expect(message).to be_held
        expect(message.hold_reason).to eq('endpoint_disabled')
      end
    end

    context 'when an eligible endpoint queue is full' do
      before { endpoint.update_columns(queued_message_count: Webhooks::CircuitPolicy::QUEUE_CAPACITY) }

      it 'rejects the whole event atomically and records the rejection' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::QueueCapacityExceededError)

        expect(project.events.count).to eq(0)
        expect(Message.where(endpoint_id: endpoint.id).count).to eq(0)
        rejection = IngestRejection.sole
        expect(rejection.project).to eq(project)
        expect(rejection.endpoint).to eq(endpoint)
        expect(rejection.reason).to eq('queue_capacity_exceeded')
        expect(rejection.event_type).to eq('order.created')
        expect(rejection.idempotency_key_digest).to eq(Digest::SHA256.hexdigest(attributes[:idempotency_key]))
        expect(rejection.payload).to eq(
          'payload_keys' => ['order_id'],
          'payload_bytes' => attributes[:payload].to_json.bytesize
        )
      end

      it 'keeps only bounded payload metadata instead of the raw event payload' do
        sensitive_attributes = attributes.merge(
          idempotency_key: 'raw-idempotency-key-must-not-persist',
          payload: {
            'order_id' => 'order-123',
            'authorization' => 'Bearer super-secret-token',
            'api_key' => 'sk_live_topsecret',
            'card' => { 'number' => '4242424242424242', 'cvv' => '123' }
          }
        )

        expect { described_class.call(project: project, attributes: sensitive_attributes) }
          .to raise_error(ApiError::QueueCapacityExceededError)

        rejection = IngestRejection.sole
        expect(rejection.payload.keys).to contain_exactly('payload_keys', 'payload_bytes')
        expect(rejection.payload['payload_keys']).to eq(%w[api_key authorization card order_id])
        expect(rejection.payload['payload_bytes']).to eq(sensitive_attributes[:payload].to_json.bytesize)
        expect(rejection.attributes.to_json).not_to include(
          'super-secret-token', 'sk_live_topsecret', '4242424242424242', 'raw-idempotency-key-must-not-persist'
        )
      end

      it 'bounds the payload metadata it keeps for support logs' do
        bulky_attributes = attributes.merge(
          payload: Array.new(30) { |index| ["key_#{index}".ljust(80, 'x'), 'value'] }.to_h
        )

        expect { described_class.call(project: project, attributes: bulky_attributes) }
          .to raise_error(ApiError::QueueCapacityExceededError)

        rejection = IngestRejection.sole
        expect(rejection.payload['payload_keys'].size).to eq(described_class::REJECTION_PAYLOAD_KEY_LIMIT)
        expect(rejection.payload['payload_keys']).to all(satisfy { |key| key.length <= described_class::REJECTION_PAYLOAD_KEY_MAX_LENGTH })
      end

      it 'does not reserve the idempotency key so a later retry can succeed' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::QueueCapacityExceededError)

        endpoint.update_columns(queued_message_count: 0)
        result = described_class.call(project: project, attributes: attributes)

        expect(result.created).to be(true)
        expect(result.messages_count).to eq(1)
        expect(project.events.count).to eq(1)
      end
    end
  end

  describe 'concurrent fan-out' do
    self.use_transactional_tests = false

    after { project.destroy! }

    it 'keeps the endpoint queue counter aligned with the created messages' do
      start = Queue.new

      threads = Array.new(3) do |index|
        Thread.new do
          start.pop
          ActiveRecord::Base.connection_pool.with_connection do
            described_class.call(
              project: Project.find(project.id),
              attributes: {
                event_type: 'order.created',
                payload: { 'index' => index },
                idempotency_key: "concurrent-#{index}"
              }
            )
          end
        end
      end

      3.times { start.push(true) }
      threads.each(&:join)

      expect(endpoint.reload.queued_message_count).to eq(3)
      expect(endpoint.messages.pending.count).to eq(3)
    end
  end

  describe '.call delivery usage' do
    context 'when several endpoints are subscribed to the event' do
      it 'reserves one delivery of the monthly quota per fanned out message' do
        create(:endpoint, project: project, event_types: [Endpoint::WILDCARD_EVENT_TYPE])

        described_class.call(project: project, attributes: attributes)

        expect(account.deliveries_used_in_period).to eq(2)
      end
    end

    context 'when the same event is ingested twice with the same idempotency key' do
      it 'counts the deliveries only once' do
        described_class.call(project: project, attributes: attributes)
        described_class.call(project: project, attributes: attributes)

        expect(account.deliveries_used_in_period).to eq(1)
      end

      context 'when the monthly delivery limit is reached in between' do
        before do
          described_class.call(project: project, attributes: attributes)
          limit = Plans::Entitlements.monthly_delivery_limit(account)
          UserUsagePeriod.reserve_deliveries(user: account, quantity: limit - 1, limit: limit)
        end

        it 'returns the accepted event instead of a payment required error' do
          result = described_class.call(project: project, attributes: attributes)

          expect(result.created).to be(false)
          expect(result.event).to eq(Event.find_by(idempotency_key: attributes[:idempotency_key]))
          expect(project.ingest_rejections).to be_empty
        end
      end
    end

    context 'when the project reached the monthly delivery limit' do
      let(:limit) { Plans::Entitlements.monthly_delivery_limit(account) }

      before do
        UserUsagePeriod.reserve_deliveries(user: account, quantity: limit, limit: limit)
      end

      it 'rejects the event with a payment required error' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError) { |error|
            expect(error.status).to eq(402)
            expect(error.code).to eq('plan_limit_exceeded')
            expect(error.errors).to contain_exactly(hash_including(field: 'monthly_delivery_limit'))
            expect(error.used).to eq(limit)
            expect(error.limit).to eq(limit)
            expect(error.period_ends).to eq(UserUsagePeriod.period_ends_at)
          }
      end

      it 'does not persist the event, the messages or extra usage' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError)

        expect(project.events.count).to eq(0)
        expect(Message.count).to eq(0)
        expect(project.endpoints.sum(:queued_message_count)).to eq(0)
        expect(account.deliveries_used_in_period).to eq(limit)
      end

      it 'records a durable ingest rejection for the project' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError)

        rejection = project.ingest_rejections.sole
        expect(rejection.reason).to eq(IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED)
        expect(rejection.endpoint_id).to be_nil
        expect(rejection.event_type).to eq('order.created')
        expect(rejection.payload).to eq(
          'payload_keys' => ['order_id'],
          'payload_bytes' => attributes[:payload].to_json.bytesize
        )
      end

      it 'stores a digest of the idempotency key instead of the raw key' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError)

        rejection = project.ingest_rejections.sole
        expect(rejection.idempotency_key_digest).to eq(Digest::SHA256.hexdigest(attributes[:idempotency_key]))
        expect(rejection.idempotency_key_digest).not_to eq(attributes[:idempotency_key])
        expect(IngestRejection.column_names).not_to include('idempotency_key')
      end
    end

    context 'when the remaining monthly quota is smaller than the fan out' do
      before do
        limit = Plans::Entitlements.monthly_delivery_limit(account)
        UserUsagePeriod.reserve_deliveries(user: account, quantity: limit - 1, limit: limit)
        create(:endpoint, project: project, event_types: [Endpoint::WILDCARD_EVENT_TYPE])
      end

      it 'rejects instead of partially reserving the quota' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError)

        expect(account.deliveries_used_in_period).to eq(Plans::Entitlements.monthly_delivery_limit(account) - 1)
      end
    end

    context 'when the project is on the pro plan' do
      let(:project) { create(:project, :pro) }

      before do
        free_limit = Plans::Entitlements.definition_for(User::FREE_PLAN).monthly_delivery_limit
        UserUsagePeriod.reserve_deliveries(user: account, quantity: free_limit, limit: free_limit)
      end

      it 'still meters and accepts deliveries beyond the free limit' do
        described_class.call(project: project, attributes: attributes)

        expect(account.deliveries_used_in_period)
          .to eq(Plans::Entitlements.definition_for(User::FREE_PLAN).monthly_delivery_limit + 1)
      end
    end

    context 'when the ingested project is owned by another account' do
      let(:member) { create(:user) }

      before { create(:project_membership, project: project, user: member, role: :maintainer) }

      it 'meters the usage of the billing owner only' do
        described_class.call(project: project, attributes: attributes)

        expect(account.deliveries_used_in_period).to eq(1)
        expect(member.deliveries_used_in_period).to eq(0)
      end
    end

    context 'when the billing account owns several projects' do
      let!(:sibling_project) { create(:project, :with_owner, owner: account) }

      before { create(:endpoint, project: sibling_project, event_types: [Endpoint::WILDCARD_EVENT_TYPE]) }

      it 'meters every project delivery against the same monthly account usage' do
        described_class.call(project: project, attributes: attributes)
        described_class.call(project: sibling_project, attributes: attributes.merge(idempotency_key: 'sibling-key'))

        expect(account.deliveries_used_in_period).to eq(2)
      end
    end
  end
end
