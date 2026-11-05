require 'rails_helper'

describe Replays::BulkPolicy do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  def failed_message(target_endpoint = endpoint)
    create(:message, project: project, endpoint: target_endpoint, status: :failed)
  end

  describe '.enforce!' do
    it 'returns the eligible count while the run stays within the cap' do
      create_list(:message, 2, project: project, endpoint: endpoint, status: :failed)

      expect(described_class.enforce!(project: project, filters: {})).to eq(2)
    end

    it 'rejects a run that exceeds the cap with the eligible count and the limit' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2)
      create_list(:message, 3, project: project, endpoint: endpoint, status: :failed)

      expect { described_class.enforce!(project: project, filters: {}) }
        .to raise_error(ApiError::BulkReplayLimitExceededError) { |error|
          expect(error.status).to eq(422)
          expect(error.code).to eq(ApiError::BulkReplayLimitExceededError::CODE)
          expect(error.eligible).to eq(3)
          expect(error.limit).to eq(2)
          expect(error.message).to include('3 eligible deliveries')
        }
    end

    it 'counts only the live eligible candidates of the project' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2)
      failed_message
      failed_message(create(:endpoint, project: project, archived_at: Time.current))
      failed_message(create(:endpoint, project: project, active: false))
      failed_message(create(:endpoint, project: project, circuit_state: :disabled))
      other_project = create(:project)
      create(:message, project: other_project, endpoint: create(:endpoint, project: other_project), status: :failed)

      expect(described_class.enforce!(project: project, filters: {})).to eq(1)
    end

    it 'counts messages that already have an active replay as unavailable' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 1)
      message = failed_message
      create(:replay_item, message: message)

      expect(described_class.enforce!(project: project, filters: {})).to eq(0)
    end

    it 'counts circuit-open candidates as eligible because they become held items' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 1)
      open_endpoint = create(:endpoint, project: project, circuit_state: :circuit_open)
      create_list(:message, 2, project: project, endpoint: open_endpoint, status: :failed)

      expect { described_class.enforce!(project: project, filters: {}) }
        .to raise_error(ApiError::BulkReplayLimitExceededError) { |error| expect(error.eligible).to eq(2) }
    end

    it 'honours the same filters as the candidate snapshot' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 1)
      paid_event = create(:event, project: project, event_type: 'order.paid')
      create(:message, event: paid_event, endpoint: endpoint, status: :failed)
      create_list(:message, 2, project: project, endpoint: endpoint, status: :failed)

      expect(described_class.enforce!(project: project, filters: { event_type: 'order.paid' })).to eq(1)
    end
  end
end
