require 'rails_helper'

describe Replays::BulkJob, type: :job do
  let(:project) { create(:project, :pro, :with_owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:run) do
    create(:replay_run, project: project, mode: ReplayRun::MODE_BULK,
                        materialized_at: nil, requested_count: 0, as_of: Time.current)
  end

  def failed_message
    create(:message, project: project, endpoint: endpoint, status: :failed, terminal_at: Time.current)
  end

  it 'is enqueued in the low queue' do
    expect { described_class.perform_later(SecureRandom.uuid) }
      .to have_enqueued_job(described_class).on_queue('low')
  end

  describe 'sidekiq options' do
    it 'uses a bounded retry for transient materialization failures' do
      expect(described_class.sidekiq_options['retry']).to eq(5)
    end
  end

  describe '#perform' do
    it 'snapshots candidates before enqueuing deliveries' do
      failed_message

      expect(Replays::EnqueueDeliveries).to receive(:call).with(run: run).once do
        expect(run.reload.replay_items.count).to eq(1)
        expect(run.requested_count).to eq(1)
      end

      described_class.perform_now(run.id)

      expect(run.reload.replay_items.count).to eq(1)
    end

    it 'uses the cutoff captured on the run instead of the worker clock' do
      frozen = Time.zone.local(2026, 1, 1, 12, 0, 0)
      run.update!(as_of: frozen)
      before = failed_message
      before.update_columns(terminal_at: frozen - 1.minute)
      after = failed_message
      after.update_columns(terminal_at: frozen + 1.minute)

      travel_to(frozen + 1.hour) { described_class.perform_now(run.id) }

      expect(run.replay_items.pluck(:message_id)).to contain_exactly(before.id)
    end

    it 'discards a replay run that no longer exists' do
      expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
    end

    it 'does not re-run a failed run' do
      run.update!(failed_at: Time.current, failure_reason: ReplayRun::FAILURE_REASON_QUOTA)
      expect(Replays::Snapshot).not_to receive(:call)

      described_class.perform_now(run.id)
    end

    context 'when the monthly quota is exhausted during snapshot' do
      let(:account) { project.effective_billing_owner }
      let(:limit) { Plans::Entitlements.monthly_delivery_limit(account) }

      before do
        failed_message
        UserUsagePeriod.reserve_deliveries!(user: account, quantity: limit, limit: limit)
      end

      it 'marks the run failed and leaves no items or reservation behind' do
        described_class.perform_now(run.id)

        run.reload
        expect(run.progress[:status]).to eq(ReplayRun::STATUS_FAILED)
        expect(run.failure_reason).to eq(ReplayRun::FAILURE_REASON_QUOTA)
        expect(run.failed_at).to be_present
        expect(run.replay_items).to be_empty
        expect(account.deliveries_used_in_period).to eq(limit)
      end
    end

    context 'when the eligible count exceeds the per-run limit' do
      before do
        stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 1)
        2.times { failed_message }
      end

      it 'marks the run failed with the over-limit reason and leaves no items' do
        described_class.perform_now(run.id)

        run.reload
        expect(run.progress[:status]).to eq(ReplayRun::STATUS_FAILED)
        expect(run.failure_reason).to eq(ReplayRun::FAILURE_REASON_OVER_LIMIT)
        expect(run.replay_items).to be_empty
      end
    end

    context 'when the job runs twice after a successful snapshot' do
      before do
        failed_message
        allow(Replays::DeliverJob).to receive(:perform_later)
      end

      it 'does not double-reserve quota, double-insert items, or double-enqueue deliveries' do
        described_class.perform_now(run.id)

        expect(run.reload.replay_items.count).to eq(1)
        expect(project.effective_billing_owner.deliveries_used_in_period).to eq(1)
        expect(Replays::DeliverJob).to have_received(:perform_later).once

        described_class.perform_now(run.id)

        expect(run.reload.replay_items.count).to eq(1)
        expect(project.effective_billing_owner.deliveries_used_in_period).to eq(1)
        expect(Replays::DeliverJob).to have_received(:perform_later).once
      end
    end
  end
end
