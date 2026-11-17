require 'rails_helper'

describe Replays::Create, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }
  let(:actor) { create(:user) }
  let(:job) { class_double(Replays::DeliverJob, perform_later: nil) }
  let(:operation) { described_class.new(job: job) }

  def eligible_failed_message
    message.update_columns(status: 'failed', terminal_at: Time.current)
    message
  end

  describe '.call' do
    context 'when the message is eligible' do
      before { eligible_failed_message }

      it 'creates a single replay run and a queued item' do
        run = operation.call(message: message, actor: actor)

        expect(run).to be_persisted
        expect(run.mode).to eq(ReplayRun::MODE_SINGLE)
        expect(run.actor).to eq(actor)
        expect(run.requested_count).to eq(1)
        expect(run.materialized_at).to be_present

        item = run.replay_items.sole
        expect(item.message).to eq(message)
        expect(item.endpoint).to eq(endpoint)
        expect(item.status).to eq(ReplayItem::QUEUED_STATUS)
      end

      it 'enqueues the delivery job' do
        run = operation.call(message: message, actor: actor)

        expect(job).to have_received(:perform_later).with(run.replay_items.sole.id)
      end

      context 'when the endpoint circuit is open' do
        before { endpoint.update!(circuit_state: :circuit_open) }

        it 'creates a held item instead of enqueueing a delivery' do
          run = operation.call(message: message, actor: actor)

          item = run.replay_items.sole
          expect(item.status).to eq(ReplayItem::HELD_STATUS)
          expect(item.hold_reason).to eq(ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
          expect(job).not_to have_received(:perform_later)
        end
      end
    end

    context 'when the message is not terminally failed' do
      it 'rejects a pending message' do
        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::REASON_MESSAGES.fetch(Replays::Eligibility::REASON_NOT_TERMINAL))
      end

      it 'rejects a delivering message' do
        message.update_columns(status: 'delivering')

        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError)
      end

      it 'rejects a succeeded message' do
        message.update_columns(status: 'succeeded', terminal_at: Time.current)

        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::REASON_MESSAGES.fetch(Replays::Eligibility::REASON_NOT_FAILED))
      end
    end

    context 'when the message is held' do
      before do
        eligible_failed_message
        message.update_columns(held_at: Time.current, hold_reason: 'endpoint_circuit_open')
      end

      it 'rejects the replay' do
        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::REASON_MESSAGES.fetch(Replays::Eligibility::REASON_HELD))
      end
    end

    context 'when the endpoint is not replayable' do
      before { eligible_failed_message }

      it 'rejects an archived endpoint' do
        endpoint.update!(archived_at: Time.current)

        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::REASON_MESSAGES.fetch(Replays::Eligibility::REASON_ENDPOINT_ARCHIVED))
      end

      it 'rejects a paused endpoint' do
        endpoint.update!(active: false)

        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::REASON_MESSAGES.fetch(Replays::Eligibility::REASON_ENDPOINT_PAUSED))
      end

      it 'rejects a disabled endpoint' do
        endpoint.update!(circuit_state: :disabled)

        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::REASON_MESSAGES.fetch(Replays::Eligibility::REASON_ENDPOINT_DISABLED))
      end
    end

    context 'when a replay is already in progress' do
      before do
        eligible_failed_message
        create(:replay_item, message: message, endpoint: endpoint, status: ReplayItem::QUEUED_STATUS)
      end

      it 'rejects the duplicate replay' do
        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::UnprocessableEntityError, described_class::REASON_MESSAGES.fetch(Replays::Eligibility::REASON_REPLAY_IN_PROGRESS))
      end
    end

    it 'does not create a run when the eligibility check fails' do
      expect { operation.call(message: message, actor: actor) }
        .to raise_error(ApiError::UnprocessableEntityError)
      expect(ReplayRun.count).to eq(0)
    end
  end
end
