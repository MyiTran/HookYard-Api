require 'rails_helper'

describe Endpoints::Create, type: :operation do
  let(:project) { create(:project, :with_owner) }

  describe '.call' do
    it 'creates an endpoint scoped to the project with an initial signing secret' do
      endpoint = described_class.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' })

      expect(endpoint).to be_persisted
      expect(endpoint.project).to eq(project)
      expect(endpoint.current_signing_secret.version).to eq(1)
      expect(endpoint.current_signing_secret.secret).to be_present
      expect(endpoint.current_signing_secret).not_to be_retired
    end

    it 'persists the requested event type subscriptions' do
      endpoint = described_class.call(
        project: project,
        attributes: { name: 'Billing', url: 'https://example.com/hooks', event_types: %w[order.created order.updated] }
      )

      expect(endpoint.event_types).to contain_exactly('order.created', 'order.updated')
    end

    it 'raises when the attributes are invalid' do
      expect { described_class.call(project: project, attributes: { name: '', url: '' }) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(project.endpoints.count).to eq(0)
    end
  end

  describe '.call with the plan endpoint limit' do
    context 'when the project is at the free endpoint limit' do
      before { create_list(:endpoint, Plans::Entitlements.endpoint_limit(project), project: project) }

      it 'rejects the endpoint with a payment required error' do
        expect do
          described_class.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' })
        end.to raise_error(ApiError::PlanLimitExceededError) { |error|
          expect(error.status).to eq(402)
          expect(error.code).to eq('plan_limit_exceeded')
          expect(error.errors).to contain_exactly(hash_including(field: 'endpoint_limit'))
          expect(error.used).to eq(Plans::Entitlements.endpoint_limit(project))
          expect(error.limit).to eq(Plans::Entitlements.endpoint_limit(project))
          expect(error.period_ends).to be_nil
        }

        expect(project.endpoints.not_archived.count).to eq(Plans::Entitlements.endpoint_limit(project))
      end
    end

    context 'when the project is below the free endpoint limit' do
      before { create_list(:endpoint, Plans::Entitlements.endpoint_limit(project) - 1, project: project) }

      it 'creates the endpoint that fills the last slot' do
        endpoint = described_class.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' })

        expect(endpoint).to be_persisted
      end
    end

    context 'when the project has archived endpoints' do
      before do
        create_list(:endpoint, Plans::Entitlements.endpoint_limit(project), project: project, archived_at: Time.current)
      end

      it 'does not count archived endpoints against the limit' do
        endpoint = described_class.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' })

        expect(endpoint).to be_persisted
      end
    end

    context 'when the project is on the pro plan' do
      let(:project) { create(:project, :with_owner, plan: Project::PRO_PLAN) }

      before do
        create_list(:endpoint, Plans::Entitlements.definition_for(Project::FREE_PLAN).endpoint_limit, project: project)
      end

      it 'creates endpoints beyond the free limit' do
        endpoint = described_class.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' })

        expect(endpoint).to be_persisted
      end
    end
  end
end
