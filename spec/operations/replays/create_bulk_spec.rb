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
  end
end
