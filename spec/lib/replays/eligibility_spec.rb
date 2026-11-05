require 'rails_helper'

describe Replays::Eligibility do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:message) { create(:message, project: project, endpoint: endpoint, status: message_status) }
  let(:message_status) { :failed }

  describe '.for_message' do
    context 'when the message terminally failed' do
      it 'allows the replay' do
        expect(described_class.for_message(message)).to be_allowed
      end
    end

    context 'when the message is still pending' do
      let(:message_status) { :pending }

      it 'blocks the replay with the non-terminal reason' do
        result = described_class.for_message(message)

        expect(result).not_to be_allowed
        expect(result.reason).to eq(described_class::REASON_NOT_TERMINAL)
      end
    end

    context 'when the message is being delivered' do
      let(:message_status) { :delivering }

      it 'blocks the replay with the non-terminal reason' do
        expect(described_class.for_message(message).reason).to eq(described_class::REASON_NOT_TERMINAL)
      end
    end

    context 'when the message already succeeded' do
      let(:message_status) { :succeeded }

      it 'blocks the replay because only failed messages can be replayed' do
        result = described_class.for_message(message)

        expect(result).not_to be_allowed
        expect(result.reason).to eq(described_class::REASON_NOT_FAILED)
      end
    end

    context 'when the message is held by the circuit breaker' do
      let(:message_status) { :pending }

      before { message.update!(held_at: Time.current, hold_reason: Webhooks::CircuitPolicy::HOLD_REASONS[:circuit_open]) }

      it 'blocks the replay' do
        expect(described_class.for_message(message).reason).to eq(described_class::REASON_HELD)
      end
    end

    context 'when the endpoint is archived' do
      before { endpoint.update!(archived_at: Time.current) }

      it 'blocks the replay' do
        expect(described_class.for_message(message).reason).to eq(described_class::REASON_ENDPOINT_ARCHIVED)
      end
    end

    context 'when the endpoint is paused' do
      before { endpoint.update!(active: false) }

      it 'blocks the replay' do
        expect(described_class.for_message(message).reason).to eq(described_class::REASON_ENDPOINT_PAUSED)
      end
    end

    context 'when the endpoint is disabled' do
      before { endpoint.update!(circuit_state: :disabled) }

      it 'blocks the replay' do
        expect(described_class.for_message(message).reason).to eq(described_class::REASON_ENDPOINT_DISABLED)
      end
    end

    context 'when the endpoint circuit is open' do
      before { endpoint.update!(circuit_state: :circuit_open) }

      it 'allows the replay so it can be queued while held' do
        expect(described_class.for_message(message)).to be_allowed
      end
    end

    context 'when a replay is already in progress for the message' do
      before { create(:replay_item, message: message) }

      it 'blocks the second replay' do
        expect(described_class.for_message(message).reason).to eq(described_class::REASON_REPLAY_IN_PROGRESS)
      end
    end

    context 'when the previous replay already finished' do
      before { create(:replay_item, message: message, status: ReplayItem::FAILED_STATUS, completed_at: Time.current) }

      it 'allows another replay' do
        expect(described_class.for_message(message)).to be_allowed
      end
    end
  end

  describe '.summary_for' do
    it 'exposes the last replay outcome without changing the message lifecycle' do
      item = create(:replay_item, message: message, status: ReplayItem::FAILED_STATUS,
                                  completed_at: Time.current, error_type: 'Net::ReadTimeout')

      summary = described_class.summary_for(message.reload)

      expect(summary).to include(allowed: true, active: false)
      expect(summary[:last_outcome]).to include(id: item.id, status: ReplayItem::FAILED_STATUS,
                                                error_type: 'Net::ReadTimeout')
    end

    context 'when the endpoint is paused' do
      before { endpoint.update!(active: false) }

      it 'returns allowed false with blocked_reason endpoint_paused' do
        expect(described_class.summary_for(message.reload)).to include(
          allowed: false,
          blocked_reason: described_class::REASON_ENDPOINT_PAUSED
        )
      end
    end

    context 'when no replay happened yet' do
      it 'returns no outcome' do
        expect(described_class.summary_for(message)).to include(last_outcome: nil)
      end
    end
  end
end
