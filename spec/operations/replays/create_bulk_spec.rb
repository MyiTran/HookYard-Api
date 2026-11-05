require 'rails_helper'

describe Replays::CreateBulk, type: :operation do
  let(:owner) { create(:user, :pro) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:job) { class_double(Replays::BulkJob, perform_later: true) }
  let(:http_client) { double('http_client') }
  let(:operation) { described_class.new(job: job) }

  def failed_message
    create(:message, project: project, endpoint: endpoint, status: :failed)
  end

  def confirm(filters: {})
    operation.call(project: project, actor: owner, filters: filters)
  end

  describe '.call' do
    it 'freezes the previewed candidate set at confirmation time' do
      message = failed_message
      preview = Replays::Preview.call(project: project, filters: {})

      run = confirm

      expect(preview.eligible_count).to eq(1)
      expect(run.replay_items.pluck(:message_id)).to eq([message.id])
      expect(run.progress[:summary]).to include(requested: 1, eligible: 1, blocked: 0, queued: 1)
      expect(job).to have_received(:perform_later).with(run.id)
    end

    it 'does not include a message that fails after the confirmation' do
      confirm
      late = failed_message

      Replays::EnqueueDeliveries.call(run: ReplayRun.last)

      expect(ReplayRun.last.replay_items.pluck(:message_id)).not_to include(late.id)
    end

    it 'keeps the confirmed candidate in the audit when its endpoint is disabled before delivery' do
      message = failed_message
      run = confirm

      endpoint.update!(circuit_state: :disabled)
      Replays::EnqueueDeliveries.call(run: run)
      allow(http_client).to receive(:post)

      item = run.replay_items.find_by(message_id: message.id)
      Replays::Deliver.new(http_client: http_client).call(item: item)

      expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)
      expect(item.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_DISABLED)
      expect(http_client).not_to have_received(:post)
      expect(run.reload.progress[:summary]).to include(requested: 1, eligible: 1, blocked: 0, skipped: 1)
    end

    it 'rejects a project that is not on the pro plan without creating a run' do
      free_project = create(:project, :with_owner)

      expect { operation.call(project: free_project, actor: owner, filters: {}) }
        .to raise_error(ApiError::NotAuthorizedError) { |error| expect(error.status).to eq(403) }
      expect(ReplayRun.count).to eq(0)
      expect(job).not_to have_received(:perform_later)
    end

    context 'when the confirmed candidates exceed the cap' do
      before { stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2) }

      it 'rejects the confirmation without creating a run, items, attempts or jobs' do
        create_list(:message, 3, project: project, endpoint: endpoint, status: :failed)

        expect { confirm }.to raise_error(ApiError::BulkReplayLimitExceededError) { |error|
          expect(error.eligible).to eq(3)
          expect(error.limit).to eq(2)
        }

        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(DeliveryAttempt.count).to eq(0)
        expect(job).not_to have_received(:perform_later)
      end

      it 'accepts a run that fills the cap exactly' do
        messages = create_list(:message, 2, project: project, endpoint: endpoint, status: :failed)

        run = confirm

        expect(run.replay_items.pluck(:message_id)).to match_array(messages.map(&:id))
        expect(job).to have_received(:perform_later).with(run.id)
      end

      it 'rejects a set that grew past the cap between preview and confirmation' do
        create_list(:message, 2, project: project, endpoint: endpoint, status: :failed)
        preview = Replays::Preview.call(project: project, filters: {})
        failed_message

        expect(preview.over_limit).to be(false)

        expect { confirm }.to raise_error(ApiError::BulkReplayLimitExceededError) { |error|
          expect(error.eligible).to eq(3)
        }

        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(job).not_to have_received(:perform_later)
      end

      it 'rolls the whole run back when the cap count under-reports the frozen set' do
        allow(ReplayCandidatesQuery).to receive(:count).and_return(0)
        create_list(:message, 3, project: project, endpoint: endpoint, status: :failed)

        expect { confirm }.to raise_error(ApiError::BulkReplayLimitExceededError) { |error|
          expect(error.eligible).to eq(3)
        }

        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(job).not_to have_received(:perform_later)
      end
    end

    context 'when the confirmed candidates belong to a circuit-open endpoint' do
      let(:open_endpoint) { create(:endpoint, project: project, circuit_state: :circuit_open) }

      it 'accepts them as held items that wait for the normal circuit release' do
        messages = create_list(:message, 2, project: project, endpoint: open_endpoint, status: :failed)
        preview = Replays::Preview.call(project: project, filters: {})

        run = confirm

        expect(preview.requested_count).to eq(2)
        expect(preview.eligible_count).to eq(2)
        expect(preview.blocked_count).to eq(0)
        expect(run.replay_items.pluck(:message_id)).to match_array(messages.map(&:id))
        expect(run.replay_items.pluck(:status).uniq).to eq([ReplayItem::HELD_STATUS])
        expect(run.replay_items.pluck(:hold_reason).uniq).to eq([ReplayItem::HOLD_REASON_CIRCUIT_OPEN])

        allow(http_client).to receive(:post)
        run.replay_items.each { |item| Replays::Deliver.new(http_client: http_client).call(item: item) }

        expect(run.replay_items.reload.pluck(:status).uniq).to eq([ReplayItem::HELD_STATUS])
        expect(DeliveryAttempt.count).to eq(0)
        expect(http_client).not_to have_received(:post)

        open_endpoint.close_circuit!
        Replays::ReleaseHeld.call(endpoint: open_endpoint)

        expect(run.replay_items.reload.pluck(:status).uniq).to eq([ReplayItem::QUEUED_STATUS])
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job[:job] })
          .to include(Replays::DeliverJob)
      end
    end

    context 'when candidates belong to a paused endpoint' do
      it 'leaves them out of the snapshot' do
        paused = create(:endpoint, project: project, active: false)
        create_list(:message, 2, project: project, endpoint: paused, status: :failed)
        eligible = failed_message

        run = confirm

        expect(run.replay_items.pluck(:message_id)).to eq([eligible.id])
        expect(run.reload.progress[:summary]).to include(requested: 3, eligible: 1, blocked: 2)
      end
    end
  end
end
