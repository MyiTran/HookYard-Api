require 'rails_helper'

describe Replays::Preview, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  def failed_message(target_endpoint = endpoint)
    create(:message, project: project, endpoint: target_endpoint, status: :failed)
  end

  describe '.call' do
    it 'counts the requested, eligible and blocked messages' do
      failed_message
      disabled = create(:endpoint, project: project, circuit_state: :disabled)
      failed_message(disabled)
      create(:message, project: project, endpoint: endpoint, status: :succeeded)

      preview = described_class.call(project: project, filters: {})

      expect(preview.requested_count).to eq(2)
      expect(preview.eligible_count).to eq(1)
      expect(preview.blocked_count).to eq(1)
    end

    it 'reports paused endpoint candidates as blocked rather than eligible' do
      paused = create(:endpoint, project: project, active: false)
      create_list(:message, 2, project: project, endpoint: paused, status: :failed)

      preview = described_class.call(project: project, filters: { endpoint_id: paused.id })

      expect(preview.requested_count).to eq(2)
      expect(preview.eligible_count).to eq(0)
      expect(preview.blocked_count).to eq(2)
      expect(preview.sample).to be_empty
    end

    it 'returns a bounded sample of the replayable messages' do
      create_list(:message, 7, project: project, endpoint: endpoint, status: :failed)

      preview = described_class.call(project: project, filters: {})

      expect(preview.sample.size).to eq(described_class::SAMPLE_LIMIT)
      expect(preview.sample).to all(be_failed)
    end

    it 'honours the delivery log filters' do
      matching_event = create(:event, project: project, event_type: 'order.paid')
      create(:message, event: matching_event, endpoint: endpoint, status: :failed)
      failed_message

      preview = described_class.call(project: project, filters: { event_type: 'order.paid' })

      expect(preview.eligible_count).to eq(1)
      expect(preview.sample.map { |message| message.event.event_type }).to eq(['order.paid'])
    end

    it 'does not include messages of other projects' do
      other_project = create(:project)
      create(:message, project: other_project, endpoint: create(:endpoint, project: other_project), status: :failed)

      expect(described_class.call(project: project, filters: {}).requested_count).to eq(0)
    end

    it 'reports the real cap and never flags a small confirmation' do
      failed_message

      preview = described_class.call(project: project, filters: {})

      expect(preview.max_items_per_run).to eq(20_000)
      expect(preview.over_limit).to be(false)
    end

    it 'flags a confirmation that would exceed the cap' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2)
      create_list(:message, 3, project: project, endpoint: endpoint, status: :failed)

      preview = described_class.call(project: project, filters: {})

      expect(preview.eligible_count).to eq(3)
      expect(preview.max_items_per_run).to eq(2)
      expect(preview.over_limit).to be(true)
    end

    it 'does not flag a confirmation that fills the cap exactly' do
      stub_const('Replays::BulkPolicy::MAX_ITEMS_PER_RUN', 2)
      create_list(:message, 2, project: project, endpoint: endpoint, status: :failed)

      expect(described_class.call(project: project, filters: {}).over_limit).to be(false)
    end
  end
end
