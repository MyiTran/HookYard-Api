require 'rails_helper'

describe Messages::BackfillDeliveryRetryFields, type: :operation do
  let(:project) { create(:project) }

  def create_legacy_message(attempts: 0, attempt_count: 0, status: 'pending', terminal_at: nil)
    message = create(:message, project: project)
    attempts.times { |index| create(:delivery_attempt, message: message, attempt_number: index + 1) }
    message.update_columns(attempt_count: attempt_count, status: status, terminal_at: terminal_at)

    message
  end

  describe '.call' do
    it 'derives attempt_count from the recorded delivery attempts' do
      message = create_legacy_message(attempts: 3)

      described_class.call

      expect(message.reload.attempt_count).to eq(3)
    end

    it 'fills terminal_at from the existing updated_at for terminal messages' do
      succeeded_at = 2.days.ago.change(usec: 0)
      succeeded = create_legacy_message(attempts: 1, status: 'succeeded')
      succeeded.update_columns(updated_at: succeeded_at)
      pending_message = create_legacy_message

      described_class.call

      expect(succeeded.reload.terminal_at).to eq(succeeded_at)
      expect(pending_message.reload.terminal_at).to be_nil
    end

    it 'keeps the newest attempt_count instead of overwriting it with fewer attempts' do
      message = create_legacy_message(attempts: 2, attempt_count: 5)

      described_class.call

      expect(message.reload.attempt_count).to eq(5)
    end

    it 'leaves an already backfilled message untouched when run again' do
      message = create_legacy_message(attempts: 2, status: 'failed')

      described_class.call
      first_run = message.reload.attributes
      described_class.call
      message.reload

      expect(message.attributes).to eq(first_run)
      expect(message.attempt_count).to eq(2)
      expect(message.terminal_at).to eq(first_run['updated_at'])
    end

    it 'only rewrites the retry fields of the message' do
      message = create_legacy_message(attempts: 2, status: 'failed')
      original_updated_at = message.reload.updated_at
      expect(Webhooks::HttpClient).not_to receive(:new)
      expect(Webhooks::Signer).not_to receive(:sign)

      expect { described_class.call }.not_to have_enqueued_job

      message.reload
      expect(message.status).to eq('failed')
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.attempt_count).to eq(2)
      expect(message.delivery_attempts.count).to eq(2)
      expect(message.updated_at).to eq(original_updated_at)
    end

    it 'walks the messages with bounded keyset batches' do
      messages = Array.new(5) { create_legacy_message(attempts: 1) }
      batch_queries = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        batch_queries << payload[:sql] if payload[:sql].include?('FROM "messages"')
      end

      described_class.call(batch_size: 2)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(batch_queries.size).to eq(3)
      expect(messages.map { |message| message.reload.attempt_count }).to all(eq(1))
    end

    it 'backfills every message exactly once across batch boundaries' do
      messages = Array.new(5) { |index| create_legacy_message(attempts: (index % 3) + 1) }

      described_class.call(batch_size: 2)

      expect(messages.map { |message| message.reload.attempt_count }).to eq([1, 2, 3, 1, 2])
    end

    context 'with an invalid batch size' do
      [0, -7, 2.5, '10', nil].each do |invalid_batch_size|
        it "rejects #{invalid_batch_size.inspect}" do
          expect { described_class.call(batch_size: invalid_batch_size) }
            .to raise_error(ArgumentError, 'batch_size must be a positive integer')
        end
      end

      it 'does not touch any message before raising' do
        message = create_legacy_message(attempts: 2)

        expect { described_class.call(batch_size: 0) }.to raise_error(ArgumentError)

        expect(message.reload.attempt_count).to eq(0)
      end
    end

    context 'when the retry columns are not deployed' do
      it 'does nothing instead of querying the missing columns' do
        message = create_legacy_message(attempts: 1)
        allow(Message).to receive(:column_names)
          .and_return(Message.column_names - Messages::BackfillDeliveryRetryFields::RETRY_COLUMNS)
        allow(described_class).to receive(:new).and_call_original
        expect(Message).to receive(:reset_column_information).at_least(:once).and_call_original
        expect(Message).not_to receive(:order)

        expect { described_class.call }.not_to raise_error

        expect(message.reload.attempt_count).to eq(0)
        expect(message.terminal_at).to be_nil
      end
    end
  end
end
