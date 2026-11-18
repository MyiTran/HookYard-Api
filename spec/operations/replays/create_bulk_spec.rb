require 'rails_helper'

describe Replays::CreateBulk, type: :operation do
  let(:project) { create(:project, :pro, :with_owner) }
  let(:actor) { project.owner }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:job) { class_double(Replays::BulkJob, perform_later: nil) }
  let(:operation) { described_class.new(job: job) }

  describe '.call' do
    it 'requires the pro plan' do
      free_project = create(:project, :with_owner)

      expect { described_class.call(project: free_project, actor: free_project.owner, filters: {}) }
        .to raise_error(ApiError::NotAuthorizedError, described_class::PLAN_REQUIRED_MESSAGE)
    end

    it 'creates a queued bulk run without materializing candidates' do
      create(:message, project: project, endpoint: endpoint, status: :failed)

      run = operation.call(project: project, actor: actor, filters: { endpoint_id: endpoint.id })

      expect(run).to be_persisted
      expect(run.mode).to eq(ReplayRun::MODE_BULK)
      expect(run.materialized_at).to be_nil
      expect(run.as_of).to be_present
      expect(run.filters).to eq('endpoint_id' => endpoint.id)
      expect(run.requested_count).to eq(0)
      expect(run.replay_items).to be_empty
      expect(job).to have_received(:perform_later).with(run.id)
    end

    it 'does not snapshot or reserve quota during the request' do
      create(:message, project: project, endpoint: endpoint, status: :failed)
      expect(Replays::Snapshot).not_to receive(:call)
      expect(Plans::Quota).not_to receive(:reserve_deliveries!)

      operation.call(project: project, actor: actor, filters: { endpoint_id: endpoint.id })

      expect(project.effective_billing_owner.deliveries_used_in_period).to eq(0)
    end

    it 'enqueues the bulk job with the persisted run id' do
      run = operation.call(project: project, actor: actor, filters: {})

      expect(job).to have_received(:perform_later).with(run.id)
      expect(ReplayRun.find(run.id)).to eq(run)
    end

    it 'captures the snapshot cutoff once when the run is created' do
      frozen = Time.zone.local(2026, 1, 1, 12, 0, 0)

      travel_to(frozen) do
        run = operation.call(project: project, actor: actor, filters: {})

        expect(run.as_of).to eq(frozen)
      end
    end

    it 'rejects a pro maintainer when the project billing owner is free' do
      free_owner = create(:user)
      pro_maintainer = create(:user, :pro)
      free_project = create(:project, :with_owner, owner: free_owner)
      create(:project_membership, project: free_project, user: pro_maintainer, role: :maintainer)

      expect { described_class.call(project: free_project, actor: pro_maintainer, filters: {}) }
        .to raise_error(ApiError::NotAuthorizedError, described_class::PLAN_REQUIRED_MESSAGE)
    end

    it 'allows a free maintainer when the project billing owner is pro' do
      free_maintainer = create(:user)
      create(:project_membership, project: project, user: free_maintainer, role: :maintainer)

      run = operation.call(project: project, actor: free_maintainer, filters: {})

      expect(run).to be_persisted
      expect(project.effective_billing_owner.deliveries_used_in_period).to eq(0)
      expect(free_maintainer.deliveries_used_in_period).to eq(0)
    end

    context 'when the billing owner reached the monthly delivery limit' do
      let(:account) { project.effective_billing_owner }
      let(:limit) { Plans::Entitlements.monthly_delivery_limit(account) }

      before do
        UserUsagePeriod.reserve_deliveries!(user: account, quantity: limit, limit: limit)
      end

      it 'still accepts the run and defers the quota outcome to the job' do
        run = operation.call(project: project, actor: actor, filters: {})

        expect(run).to be_persisted
        expect(run.requested_count).to eq(0)
        expect(job).to have_received(:perform_later).with(run.id)
      end
    end

    context 'when the project uses a legacy owner membership as billing owner' do
      let(:legacy_owner) { create(:user, :pro) }
      let(:project) { create(:project).tap { |record| record.update_columns(billing_owner_id: nil) } }

      before do
        create(:project_membership, project: project, user: legacy_owner, role: :owner)
      end

      it 'creates the run without reserving quota during the request' do
        run = operation.call(project: project, actor: legacy_owner, filters: {})

        expect(run).to be_persisted
        expect(legacy_owner.deliveries_used_in_period).to eq(0)
      end
    end
  end
end
