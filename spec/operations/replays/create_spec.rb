require 'rails_helper'

describe Replays::Create, type: :operation do
  let(:project) { create(:project) }
  let(:actor) { create(:user) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:message) { create(:message, project: project, endpoint: endpoint, status: :failed) }
  let(:job) { class_double(Replays::DeliverJob, perform_later: true) }
  let(:operation) { described_class.new(job: job) }

  def replay
    operation.call(message: message, actor: actor)
  end

  describe '.call' do
    context 'when the failed message is eligible' do
      it 'creates an audited run with a queued item and enqueues the replay' do
        run = replay
        item = run.replay_items.one? && run.replay_items.first

        expect(run).to have_attributes(
          project_id: project.id,
          actor_id: actor.id,
          mode: ReplayRun::MODE_SINGLE,
          requested_count: 1
        )
        expect(run.materialized_at).to be_present
        expect(item).to have_attributes(
          message_id: message.id,
          endpoint_id: endpoint.id,
          status: ReplayItem::QUEUED_STATUS
        )
        expect(job).to have_received(:perform_later).with(item.id)
      end

      it 'leaves the message lifecycle untouched' do
        expect { replay }.not_to change {
          message.reload.attributes.slice('status', 'attempt_count', 'next_retry_at', 'terminal_at')
        }
      end

      it 'does not charge the delivery metering for the replay' do
        expect { replay }.not_to change { project.billing_owner.deliveries_used_in_period }
      end
    end

    context 'when the endpoint circuit is open' do
      before { endpoint.update!(circuit_state: :circuit_open) }

      it 'queues the item as held without sending it' do
        item = replay.replay_items.first

        expect(item.status).to eq(ReplayItem::HELD_STATUS)
        expect(item.hold_reason).to eq(ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
        expect(job).not_to have_received(:perform_later)
      end
    end

    context 'when the message is not terminal failed' do
      let(:message) { create(:message, project: project, endpoint: endpoint, status: :pending) }

      it 'rejects the replay with a validation error' do
        expect { replay }.to raise_error(ApiError::UnprocessableEntityError) { |error|
          expect(error.status).to eq(422)
          expect(error.errors).to eq([{ field: 'message', message: Replays::Eligibility::REASON_NOT_TERMINAL }])
        }
        expect(ReplayRun.count).to eq(0)
      end
    end

    context 'when the message already succeeded' do
      let(:message) { create(:message, project: project, endpoint: endpoint, status: :succeeded) }

      it 'rejects the replay because only failed messages can be replayed' do
        expect { replay }.to raise_error(ApiError::UnprocessableEntityError) { |error|
          expect(error.status).to eq(422)
          expect(error.message).to eq('Only failed messages can be replayed')
          expect(error.errors).to eq([{ field: 'message', message: Replays::Eligibility::REASON_NOT_FAILED }])
        }
        expect(ReplayRun.count).to eq(0)
      end
    end

    context 'when the endpoint is archived' do
      before { endpoint.update!(archived_at: Time.current) }

      it 'rejects the replay' do
        expect { replay }.to raise_error(ApiError::UnprocessableEntityError)
        expect(ReplayItem.count).to eq(0)
      end
    end

    context 'when the endpoint is paused' do
      before { endpoint.update!(active: false) }

      it 'rejects the replay with a stable reason and does not create runs or jobs' do
        expect { replay }.to raise_error(ApiError::UnprocessableEntityError) { |error|
          expect(error.status).to eq(422)
          expect(error.message).to eq('This endpoint is paused. Resume it before replaying this delivery.')
          expect(error.errors).to eq([{ field: 'message', message: Replays::Eligibility::REASON_ENDPOINT_PAUSED }])
        }

        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(DeliveryAttempt.count).to eq(0)
        expect(job).not_to have_received(:perform_later)
        expect(message.reload).to be_failed
      end
    end

    context 'when the endpoint is disabled' do
      before { endpoint.update!(circuit_state: :disabled) }

      it 'rejects the replay' do
        expect { replay }.to raise_error(ApiError::UnprocessableEntityError) { |error|
          expect(error.errors).to eq([{ field: 'message', message: Replays::Eligibility::REASON_ENDPOINT_DISABLED }])
        }
      end
    end

    context 'when a replay is already active for the message' do
      before { create(:replay_item, message: message) }

      it 'rejects the duplicate replay' do
        expect { replay }.to raise_error(ApiError::UnprocessableEntityError) { |error|
          expect(error.errors).to eq([{ field: 'message', message: Replays::Eligibility::REASON_REPLAY_IN_PROGRESS }])
        }
        expect(ReplayRun.count).to eq(1)
      end
    end
  end
end
