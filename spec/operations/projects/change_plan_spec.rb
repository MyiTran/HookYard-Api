require 'rails_helper'

describe Projects::ChangePlan, type: :operation do
  let(:project) { create(:project, :with_owner) }

  describe '.call' do
    context 'when switching from the free plan to the pro plan' do
      it 'persists the new plan' do
        described_class.call(project: project, plan: Project::PRO_PLAN)

        expect(project.reload.plan).to eq(Project::PRO_PLAN)
        expect(project).to be_pro
      end
    end

    context 'when switching from the pro plan back to the free plan' do
      let(:project) { create(:project, :with_owner, plan: Project::PRO_PLAN) }
      let!(:endpoints) do
        Array.new(Plans::Entitlements.definition_for(Project::FREE_PLAN).endpoint_limit + 2) do |index|
          create(:endpoint, project: project, created_at: Time.utc(2026, 10, 1, 9, 0) + index.minutes)
        end
      end
      let!(:message) { create(:message, project: project, endpoint: endpoints.first) }

      it 'persists the free plan and keeps the delivery data' do
        described_class.call(project: project, plan: Project::FREE_PLAN)

        expect(project.reload.plan).to eq(Project::FREE_PLAN)
        expect(project.endpoints.not_archived.count).to eq(endpoints.size)
        expect(project.events.count).to eq(1)
        expect(Message.exists?(message.id)).to be(true)
      end

      it 'keeps every endpoint active and deliverable' do
        described_class.call(project: project, plan: Project::FREE_PLAN)

        expect(project.endpoints.where(archived_at: nil).where(active: true).count).to eq(endpoints.size)
        expect(project.endpoints.map(&:circuit_failure_count).uniq).to eq([0])
      end

      it 'keeps accepted messages in their delivery state' do
        message.update!(next_retry_at: Time.current + 5.minutes)

        expect { described_class.call(project: project, plan: Project::FREE_PLAN) }
          .not_to change { message.reload.attributes.slice('status', 'next_retry_at', 'attempt_count') }
      end

      it 'blocks creating new endpoints while the project is over the limit' do
        described_class.call(project: project, plan: Project::FREE_PLAN)

        expect { Endpoints::Create.call(project: project, attributes: { name: 'Billing', url: 'https://example.com/hooks' }) }
          .to raise_error(ApiError::PlanLimitExceededError)
      end
    end

    context 'when the plan is unknown' do
      it 'rejects the change and keeps the previous plan' do
        expect { described_class.call(project: project, plan: 'enterprise') }
          .to raise_error(ActiveRecord::RecordInvalid)

        expect(project.reload.plan).to eq(Project::FREE_PLAN)
      end
    end
  end
end
