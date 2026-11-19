require 'rails_helper'

describe Replays::EnqueueDeliveries, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:run) { create(:replay_run, project: project, mode: ReplayRun::MODE_BULK, materialized_at: nil) }
  let(:job) { class_double(Replays::DeliverJob, perform_later: nil) }
  let(:operation) { described_class.new(job: job) }

  def create_queued_item
    message = create(:message, event: create(:event, project: project), endpoint: endpoint)
    create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                         status: ReplayItem::QUEUED_STATUS)
  end

  describe '.call' do
    it 'enqueues each queued replay item and materializes the run' do
      item = create_queued_item

      operation.call(run: run)

      expect(job).to have_received(:perform_later).with(item.id).once
      expect(run.reload.materialized_at).to be_present
    end

    it 'keeps the run unmaterialized while deliveries are still being enqueued' do
      create_queued_item
      materialized_during_enqueue = nil

      allow(job).to receive(:perform_later) do
        materialized_during_enqueue = run.reload.materialized_at
      end

      operation.call(run: run)

      expect(materialized_during_enqueue).to be_nil
      expect(run.reload.materialized_at).to be_present
    end

    it 'does not enqueue the same run twice' do
      item = create_queued_item

      operation.call(run: run)
      operation.call(run: run)

      expect(job).to have_received(:perform_later).with(item.id).once
    end

    it 'does not materialize a run that is not in bulk mode' do
      single_run = create(:replay_run, project: project, mode: ReplayRun::MODE_SINGLE, materialized_at: nil)

      operation.call(run: single_run)

      expect(job).not_to have_received(:perform_later)
      expect(single_run.reload.materialized_at).to be_nil
    end

    context 'when a Sidekiq enqueue fails midway' do
      it 'leaves the run unmaterialized so a retry can re-enqueue without losing items' do
        create_queued_item
        allow(job).to receive(:perform_later).and_raise(RuntimeError, 'redis unavailable')

        expect { operation.call(run: run) }.to raise_error(RuntimeError, 'redis unavailable')

        expect(run.reload.materialized_at).to be_nil
      end

      it 'does not mark a run materialized after only some items were enqueued' do
        create_queued_item
        create_queued_item
        calls = 0
        allow(job).to receive(:perform_later) do
          calls += 1
          raise RuntimeError, 'redis unavailable' if calls > 1
        end

        expect { operation.call(run: run) }.to raise_error(RuntimeError, 'redis unavailable')

        expect(run.reload.materialized_at).to be_nil
      end
    end
  end

  describe 'concurrent materialization' do
    self.use_transactional_tests = false

    before { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }
    after { Project.delete_all }

    it 'allows only one worker to enqueue each queued item' do
      project = create(:project)
      endpoint = create(:endpoint, project: project)
      run = create(:replay_run, project: project, mode: ReplayRun::MODE_BULK, materialized_at: nil)
      items = Array.new(3) do
        message = create(:message, event: create(:event, project: project), endpoint: endpoint)
        create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                             status: ReplayItem::QUEUED_STATUS)
      end

      run_id = run.id
      barrier = Queue.new
      threads = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.pop
            described_class.call(run: ReplayRun.find(run_id))
          end
        end
      end

      2.times { barrier << true }
      threads.each(&:join)

      enqueued_item_ids = ActiveJob::Base.queue_adapter.enqueued_jobs
        .select { |entry| entry[:job] == Replays::DeliverJob }
        .map { |entry| entry[:args].first }

      expect(enqueued_item_ids).to match_array(items.map(&:id))
      expect(ReplayRun.find(run_id).materialized_at).to be_present
    end
  end
end
