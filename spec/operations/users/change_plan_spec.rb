require 'rails_helper'

describe Users::ChangePlan, type: :operation do
  let(:account) { create(:user) }

  describe '.call' do
    context 'when switching from the free plan to the pro plan' do
      it 'persists the new plan on the account' do
        described_class.call(user: account, plan: User::PRO_PLAN)

        expect(account.reload.plan).to eq(User::PRO_PLAN)
        expect(account).to be_pro
      end

      it 'raises the limits of every project the account owns' do
        project = create(:project, :with_owner, owner: account)

        described_class.call(user: account, plan: User::PRO_PLAN)

        expect(Plans::Entitlements.endpoint_limit(account)).to eq(50)
        expect(project.reload.plan).to eq(User::PRO_PLAN)
        expect(project.plan_locked_endpoint_ids).to be_empty
      end
    end

    context 'when switching from the pro plan back to the free plan' do
      let(:account) { create(:user, :pro) }
      let!(:projects) { create_list(:project, 3, :with_owner, owner: account) }
      let(:project) { projects.first }
      let!(:endpoints) do
        Array.new(Plans::Entitlements.definition_for(User::FREE_PLAN).endpoint_limit + 1) do |index|
          create(:endpoint, project: project, created_at: Time.utc(2026, 10, 1, 9, 0) + index.minutes)
        end
      end
      let!(:message) { create(:message, project: project, endpoint: endpoints.first) }

      before { endpoints.second.update!(circuit_state: :circuit_open, circuit_failure_count: 5) }

      it 'persists the free plan and keeps every project' do
        described_class.call(user: account, plan: User::FREE_PLAN)

        expect(account.reload.plan).to eq(User::FREE_PLAN)
        expect(account.owned_projects.count).to eq(projects.size)
      end

      it 'keeps every endpoint active and deliverable' do
        described_class.call(user: account, plan: User::FREE_PLAN)

        expect(project.endpoints.where(archived_at: nil).where(active: true).count).to eq(endpoints.size)
      end

      it 'keeps the circuit state of the endpoints' do
        described_class.call(user: account, plan: User::FREE_PLAN)

        expect(endpoints.second.reload).to be_circuit_open
        expect(endpoints.second.circuit_failure_count).to eq(5)
        expect(endpoints.first.reload).to be_enabled
      end

      it 'keeps accepted messages in their delivery state' do
        message.update!(next_retry_at: Time.current + 5.minutes)

        expect { described_class.call(user: account, plan: User::FREE_PLAN) }
          .not_to change { message.reload.attributes.slice('status', 'next_retry_at', 'attempt_count') }
      end

      it 'marks the endpoints over the free limit as plan locked' do
        described_class.call(user: account, plan: User::FREE_PLAN)

        expect(project.plan_locked_endpoint_ids).to contain_exactly(endpoints.last.id)
      end

      it 'blocks creating new projects while the account is over the limit' do
        described_class.call(user: account, plan: User::FREE_PLAN)

        expect { ::Projects::Create.call(user: account, attributes: { name: 'Billing' }) }
          .to raise_error(ApiError::PlanLimitExceededError)
      end

      it 'blocks creating new endpoints while the project is over the limit' do
        described_class.call(user: account, plan: User::FREE_PLAN)

        expect { Endpoints::Create.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' }) }
          .to raise_error(ApiError::PlanLimitExceededError)
      end

      it 'blocks new deliveries once the free monthly limit is consumed' do
        endpoints.first.update!(event_types: [Endpoint::WILDCARD_EVENT_TYPE])
        free_limit = Plans::Entitlements.definition_for(User::FREE_PLAN).monthly_delivery_limit
        UserUsagePeriod.reserve_deliveries(user: account, quantity: free_limit, limit: free_limit)
        described_class.call(user: account, plan: User::FREE_PLAN)

        expect { Events::Ingest.call(project: project, attributes: { event_type: 'order.created', payload: {}, idempotency_key: 'key-1' }) }
          .to raise_error(ApiError::PlanLimitExceededError)
      end
    end

    context 'when the plan is unknown' do
      it 'rejects the change and keeps the previous plan' do
        expect { described_class.call(user: account, plan: 'enterprise') }
          .to raise_error(ActiveRecord::RecordInvalid)

        expect(account.reload.plan).to eq(User::FREE_PLAN)
      end
    end
  end
end
