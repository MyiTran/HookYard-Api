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

      it 'reserves one delivery quota for the project billing owner' do
        run = operation.call(message: message, actor: actor)

        expect(project.effective_billing_owner.deliveries_used_in_period).to eq(1)
        expect(run.replay_items.sole.quota_reserved?).to be(true)
      end

      it 'does not charge the replaying actor when they are not the billing owner' do
        operation.call(message: message, actor: actor)

        expect(actor.deliveries_used_in_period).to eq(0)
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

    context 'when the project billing owner reached the monthly delivery limit' do
      let(:account) { project.effective_billing_owner }
      let(:limit) { Plans::Entitlements.monthly_delivery_limit(account) }

      before do
        eligible_failed_message
        UserUsagePeriod.reserve_deliveries!(user: account, quantity: limit, limit: limit)
      end

      it 'rejects the replay with a payment required error and creates nothing' do
        expect { operation.call(message: message, actor: actor) }
          .to raise_error(ApiError::PlanLimitExceededError) { |error|
            expect(error.status).to eq(402)
            expect(error.code).to eq('plan_limit_exceeded')
            expect(error.used).to eq(limit)
            expect(error.limit).to eq(limit)
          }

        expect(ReplayRun.count).to eq(0)
        expect(ReplayItem.count).to eq(0)
        expect(account.deliveries_used_in_period).to eq(limit)
        expect(job).not_to have_received(:perform_later)
      end
    end

    context 'when the project uses a legacy owner membership as billing owner' do
      let(:legacy_owner) { create(:user, :pro) }
      let(:project) { create(:project).tap { |record| record.update_columns(billing_owner_id: nil) } }

      before do
        create(:project_membership, project: project, user: legacy_owner, role: :owner)
        eligible_failed_message
      end

      it 'reserves the replay against the effective billing owner' do
        operation.call(message: message, actor: actor)

        expect(legacy_owner.deliveries_used_in_period).to eq(1)
      end
    end

    it 'does not create a run when the eligibility check fails' do
      expect { operation.call(message: message, actor: actor) }
        .to raise_error(ApiError::UnprocessableEntityError)
      expect(ReplayRun.count).to eq(0)
    end
  end
end
