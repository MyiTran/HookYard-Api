require 'rails_helper'

describe Ingest::BackfillRejectionIdempotencyKeyDigestsJob, type: :job do
  let(:project) { create(:project) }

  def create_rejection(idempotency_key:, idempotency_key_digest: nil)
    IngestRejection.create!(
      project: project,
      reason: IngestRejection::QUEUE_CAPACITY_EXCEEDED,
      idempotency_key: idempotency_key,
      idempotency_key_digest: idempotency_key_digest
    )
  end

  describe '#perform' do
    it 'stores the lowercase SHA-256 hex digest of the raw key' do
      rejection = create_rejection(idempotency_key: 'order-123')

      described_class.perform_now

      expect(rejection.reload.idempotency_key_digest).to eq(Digest::SHA256.hexdigest('order-123'))
    end

    it 'does not overwrite an existing digest' do
      existing_digest = Digest::SHA256.hexdigest('already-hashed')
      rejection = create_rejection(idempotency_key: 'raw', idempotency_key_digest: existing_digest)

      described_class.perform_now

      expect(rejection.reload.idempotency_key_digest).to eq(existing_digest)
    end

    it 'is idempotent' do
      create_rejection(idempotency_key: 'raw')

      described_class.perform_now
      described_class.perform_now

      expect(IngestRejection.sole.idempotency_key_digest).to eq(Digest::SHA256.hexdigest('raw'))
    end

    it 'does not log the raw idempotency key' do
      create_rejection(idempotency_key: 'super-secret-key')
      logged_messages = []
      allow(Rails.logger).to receive(:info) { |message| logged_messages << message }

      described_class.perform_now

      expect(logged_messages.join).not_to include('super-secret-key')
    end

    it 'processes one bounded batch and enqueues the next batch' do
      rejections = Array.new(2) { |index| create_rejection(idempotency_key: "raw-#{index}") }
      ordered_rejections = IngestRejection.where(id: rejections.map(&:id)).order(:id).to_a
      first_raw_key = ordered_rejections.first.idempotency_key

      expect { described_class.perform_now(nil, 0, 1) }
        .to have_enqueued_job(described_class).with(ordered_rejections.first.id, 1, 1)

      expect(ordered_rejections.first.reload.idempotency_key_digest).to eq(Digest::SHA256.hexdigest(first_raw_key))
      expect(ordered_rejections.second.reload.idempotency_key_digest).to be_nil
    end

    it 'stops enqueueing once the batch limit is reached' do
      create_rejection(idempotency_key: 'raw')

      expect { described_class.perform_now(nil, described_class::MAX_BATCHES - 1, 1) }
        .not_to have_enqueued_job(described_class)
    end

    it 'logs a clear warning when the batch limit is reached with remaining rejections' do
      Array.new(2) { |index| create_rejection(idempotency_key: "raw-#{index}") }
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now(nil, described_class::MAX_BATCHES - 1, 1)

      expect(Rails.logger).to have_received(:warn).with(
        /ingest_rejection digest backfill stopped at MAX_BATCHES=100; 1 rejections may remain/
      )
      expect(Rails.logger).to have_received(:warn).with(
        /re-run `rails data_backfills:enqueue_plan_backfills` to continue/
      )
    end
  end
end
