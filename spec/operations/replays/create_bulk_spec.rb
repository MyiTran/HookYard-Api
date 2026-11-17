require 'rails_helper'

describe Replays::CreateBulk, type: :operation do
  let(:project) { create(:project, :pro, :with_owner) }
  let(:actor) { project.owner }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:job) { class_double(Replays::BulkJob, perform_later: nil) }
  let(:operation) { described_class.new(job: job) }

  describe '.call' do
    it 'requires the pro plan' do
      free_project = create(:project, :with_owner)

      expect { described_class.call(project: free_project, actor: free_project.owner, filters: {}) }
        .to raise_error(ApiError::NotAuthorizedError, described_class::PLAN_REQUIRED_MESSAGE)
    end

    it 'creates a bulk run and snapshots the eligible failed messages' do
      create(:message, project: project, endpoint: endpoint, status: :failed)

      run = operation.call(project: project, actor: actor, filters: { endpoint_id: endpoint.id })

      expect(run).to be_persisted
      expect(run.mode).to eq(ReplayRun::MODE_BULK)
      expect(run.materialized_at).to be_nil
      expect(run.filters).to eq('endpoint_id' => endpoint.id)
      expect(run.requested_count).to eq(1)
      expect(run.replay_items.count).to eq(1)
      expect(job).to have_received(:perform_later).with(run.id)
    end

    it 'rejects a pro maintainer when the project billing owner is free' do
      free_owner = create(:user)
      pro_maintainer = create(:user, :pro)
      free_project = create(:project, :with_owner, owner: free_owner)
      create(:project_membership, project: free_project, user: pro_maintainer, role: :maintainer)

      expect { described_class.call(project: free_project, actor: pro_maintainer, filters: {}) }
        .to raise_error(ApiError::NotAuthorizedError, described_class::PLAN_REQUIRED_MESSAGE)
    end

    it 'allows a free maintainer when the project billing owner is pro and charges the owner' do
      free_maintainer = create(:user)
      create(:project_membership, project: project, user: free_maintainer, role: :maintainer)
      create(:message, project: project, endpoint: endpoint, status: :failed)

      run = operation.call(project: project, actor: free_maintainer, filters: { endpoint_id: endpoint.id })

      expect(run).to be_persisted
      expect(project.effective_billing_owner.deliveries_used_in_period).to eq(1)
      expect(free_maintainer.deliveries_used_in_period).to eq(0)
    end

    context 'when the billing owner reached the monthly delivery limit' do
      let(:account) { project.effective_billing_owner }
      let(:limit) { Plans::Entitlements.monthly_delivery_limit(account) }

      before do
        create(:message, project: project, endpoint: endpoint, status: :failed)
        UserUsagePeriod.reserve_deliveries!(user: account, quantity: limit, limit: limit)
      end

      it 'rejects the bulk replay with a payment required error and creates nothing' do
        expect { operation.call(project: project, actor: actor, filters: { endpoint_id: endpoint.id }) }
          .to raise_error(ApiError::PlanLimitExceededError) { |error|
            expect(error.status).to eq(402)
            expect(error.code).to eq('plan_limit_exceeded')
          }

        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(account.deliveries_used_in_period).to eq(limit)
        expect(job).not_to have_received(:perform_later)
      end
    end

    context 'when a snapshot candidate conflicts with an existing active replay item' do
      let(:message_a) { create(:message, project: project, endpoint: endpoint, status: :failed) }
      let(:message_b) { create(:message, project: project, endpoint: endpoint, status: :failed) }

      before do
        create(:replay_item, message: message_a, endpoint: endpoint, status: ReplayItem::QUEUED_STATUS)
        allow(ReplayCandidatesQuery).to receive(:call).and_return(Message.where(id: [message_a.id, message_b.id]))
      end

      it 'reserves quota only for the item actually inserted' do
        run = operation.call(project: project, actor: actor, filters: { endpoint_id: endpoint.id })

        expect(run.replay_items.count).to eq(1)
        expect(run.replay_items.pluck(:message_id)).to contain_exactly(message_b.id)
        expect(project.effective_billing_owner.deliveries_used_in_period).to eq(1)
        expect(run.replay_items.sole.quota_reserved?).to be(true)
      end
    end

    context 'when a re-snapshot inserts no items' do
      before { create(:message, project: project, endpoint: endpoint, status: :failed) }

      it 'does not reserve quota for the second run' do
        first = operation.call(project: project, actor: actor, filters: { endpoint_id: endpoint.id })
        expect(first.replay_items.count).to eq(1)
        expect(project.effective_billing_owner.deliveries_used_in_period).to eq(1)

        second = operation.call(project: project, actor: actor, filters: { endpoint_id: endpoint.id })
        expect(second.replay_items.count).to eq(0)
        expect(project.effective_billing_owner.deliveries_used_in_period).to eq(1)
      end
    end

    context 'when the project uses a legacy owner membership as billing owner' do
      let(:legacy_owner) { create(:user, :pro) }
      let(:project) { create(:project).tap { |record| record.update_columns(billing_owner_id: nil) } }

      before do
        create(:project_membership, project: project, user: legacy_owner, role: :owner)
        create(:message, project: project, endpoint: endpoint, status: :failed)
      end

      it 'reserves the bulk replay against the effective billing owner' do
        run = operation.call(project: project, actor: legacy_owner, filters: { endpoint_id: endpoint.id })

        expect(run).to be_persisted
        expect(legacy_owner.deliveries_used_in_period).to eq(1)
      end
    end
  end
end
