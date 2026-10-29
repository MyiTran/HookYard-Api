require 'rails_helper'

describe Events::Ingest, type: :operation do
  let(:project) { create(:project) }
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
  end

  describe '.call delivery usage' do
    context 'when several endpoints are subscribed to the event' do
      it 'reserves one delivery of the monthly quota per fanned out message' do
        create(:endpoint, project: project, event_types: [Endpoint::WILDCARD_EVENT_TYPE])

        described_class.call(project: project, attributes: attributes)

        expect(project.reload.deliveries_used_in_period).to eq(2)
      end
    end

    context 'when the same event is ingested twice with the same idempotency key' do
      it 'counts the deliveries only once' do
        described_class.call(project: project, attributes: attributes)
        described_class.call(project: project, attributes: attributes)

        expect(project.reload.deliveries_used_in_period).to eq(1)
      end

      context 'when the monthly delivery limit is reached in between' do
        before do
          described_class.call(project: project, attributes: attributes)
          limit = Plans::Entitlements.monthly_delivery_limit(project)
          ProjectUsagePeriod.reserve_deliveries(project: project, quantity: limit - 1, limit: limit)
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
      let(:limit) { Plans::Entitlements.monthly_delivery_limit(project) }

      before do
        ProjectUsagePeriod.reserve_deliveries(project: project, quantity: limit, limit: limit)
      end

      it 'rejects the event with a payment required error' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError) { |error|
            expect(error.status).to eq(402)
            expect(error.code).to eq('plan_limit_exceeded')
            expect(error.errors).to contain_exactly(hash_including(field: 'monthly_delivery_limit'))
            expect(error.used).to eq(limit)
            expect(error.limit).to eq(limit)
            expect(error.period_ends).to eq(ProjectUsagePeriod.period_ends_at)
          }
      end

      it 'does not persist the event, the messages or extra usage' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError)

        expect(project.events.count).to eq(0)
        expect(Message.count).to eq(0)
        expect(project.endpoints.sum(:queued_message_count)).to eq(0)
        expect(project.reload.deliveries_used_in_period).to eq(limit)
      end

      it 'records a durable ingest rejection for the project' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError)

        rejection = project.ingest_rejections.sole
        expect(rejection.reason).to eq(IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED)
        expect(rejection.endpoint_id).to be_nil
        expect(rejection.event_type).to eq('order.created')
        expect(rejection.payload).to eq(attributes[:payload])
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
        limit = Plans::Entitlements.monthly_delivery_limit(project)
        ProjectUsagePeriod.reserve_deliveries(project: project, quantity: limit - 1, limit: limit)
        create(:endpoint, project: project, event_types: [Endpoint::WILDCARD_EVENT_TYPE])
      end

      it 'rejects instead of partially reserving the quota' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::PlanLimitExceededError)

        expect(project.reload.deliveries_used_in_period).to eq(Plans::Entitlements.monthly_delivery_limit(project) - 1)
      end
    end

    context 'when the project is on the pro plan' do
      let(:project) { create(:project, plan: Project::PRO_PLAN) }

      before do
        free_limit = Plans::Entitlements.definition_for(Project::FREE_PLAN).monthly_delivery_limit
        ProjectUsagePeriod.reserve_deliveries(project: project, quantity: free_limit, limit: free_limit)
      end

      it 'still meters and accepts deliveries beyond the free limit' do
        described_class.call(project: project, attributes: attributes)

        expect(project.reload.deliveries_used_in_period)
          .to eq(Plans::Entitlements.definition_for(Project::FREE_PLAN).monthly_delivery_limit + 1)
      end
    end
  end
end
