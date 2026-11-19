require 'rails_helper'

describe Billing::BackfillProjectBillingOwnersJob, type: :job do
  let(:connection) { ActiveRecord::Base.connection }
  let(:owner) { create(:user) }
  let(:other_user) { create(:user) }

  def project_without_billing_owner
    create(:project).tap { |project| project.update_columns(billing_owner_id: nil) }
  end

  describe '#perform' do
    it 'sets the owner membership as the billing owner' do
      project = project_without_billing_owner
      create(:project_membership, project: project, user: owner, role: :owner)

      described_class.perform_now

      expect(project.reload.billing_owner_id).to eq(owner.id)
    end

    it 'does not overwrite an existing billing owner' do
      project = create(:project, owner: other_user)
      create(:project_membership, project: project, user: owner, role: :owner)
      original_billing_owner_id = project.billing_owner_id

      described_class.perform_now

      expect(project.reload.billing_owner_id).to eq(original_billing_owner_id)
    end

    it 'fails loudly when a project has no owner membership' do
      project = project_without_billing_owner
      create(:project_membership, project: project, user: other_user, role: :maintainer)

      expect { described_class.perform_now }
        .to raise_error(Billing::BackfillProjectBillingOwnersJob::IncompleteError)

      expect(project.reload.billing_owner_id).to be_nil
    end

    it 'fails loudly when a project has several owner memberships' do
      connection.execute('DROP INDEX index_project_memberships_on_project_id_owner')
      project = project_without_billing_owner
      create(:project_membership, project: project, user: owner, role: :owner)
      create(:project_membership, project: project, user: other_user, role: :owner)

      expect { described_class.perform_now }
        .to raise_error(Billing::BackfillProjectBillingOwnersJob::IncompleteError)

      expect(project.reload.billing_owner_id).to be_nil
    end

    it 'is idempotent across retries' do
      project = project_without_billing_owner
      create(:project_membership, project: project, user: owner, role: :owner)

      described_class.perform_now
      described_class.perform_now

      expect(project.reload.billing_owner_id).to eq(owner.id)
    end

    it 'processes one bounded batch and enqueues the next batch' do
      projects = Array.new(2) { project_without_billing_owner }
      projects.each { |project| create(:project_membership, project: project, user: owner, role: :owner) }
      ordered_projects = Project.where(id: projects.map(&:id)).order(:id).to_a

      expect { described_class.perform_now(nil, 0, 1) }
        .to have_enqueued_job(described_class).with(ordered_projects.first.id, 1, 1)

      expect(ordered_projects.first.reload.billing_owner_id).to eq(owner.id)
      expect(ordered_projects.second.reload.billing_owner_id).to be_nil
    end

    it 'stops enqueueing once the batch limit is reached' do
      project = project_without_billing_owner
      create(:project_membership, project: project, user: owner, role: :owner)

      expect { described_class.perform_now(nil, described_class::MAX_BATCHES - 1, 1) }
        .not_to have_enqueued_job(described_class)

      expect(project.reload.billing_owner_id).to eq(owner.id)
    end

    it 'logs a clear warning when the batch limit is reached with remaining projects' do
      projects = Array.new(2) { project_without_billing_owner }
      projects.each { |project| create(:project_membership, project: project, user: owner, role: :owner) }
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now(nil, described_class::MAX_BATCHES - 1, 1)

      expect(Rails.logger).to have_received(:warn).with(
        /billing_owner backfill stopped at MAX_BATCHES=100; 1 projects with billing_owner_id IS NULL may remain/
      )
      expect(Rails.logger).to have_received(:warn).with(
        /re-run `rails data_backfills:enqueue_plan_backfills` to continue/
      )
    end
  end
end
