require 'rails_helper'

describe ReplayCandidatesQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project, event_type: 'order.created') }

  def eligible_results(**params)
    described_class.call(described_class.for_project(project), **params).to_a
  end

  def requested_results(**params)
    described_class.call(described_class.for_project(project), eligible: false, **params).to_a
  end

  def count(eligible: true, **params)
    described_class.count(described_class.for_project(project), eligible: eligible, **params)
  end

  describe '.call' do
    it 'returns only failed messages' do
      failed = create(:message, project: project, endpoint: endpoint, status: :failed)
      create(:message, project: project, endpoint: endpoint, status: :succeeded)
      create(:message, project: project, endpoint: endpoint, status: :pending)

      expect(eligible_results.map(&:id)).to contain_exactly(failed.id)
    end

    it 'excludes failed messages of an archived endpoint' do
      endpoint.update!(archived_at: Time.current)
      create(:message, project: project, endpoint: endpoint, status: :failed)

      expect(eligible_results).to be_empty
    end

    it 'excludes failed messages of a paused endpoint' do
      endpoint.update!(active: false)
      create(:message, project: project, endpoint: endpoint, status: :failed)

      expect(eligible_results).to be_empty
    end

    it 'excludes failed messages of a disabled endpoint' do
      endpoint.update!(circuit_state: :disabled)
      create(:message, project: project, endpoint: endpoint, status: :failed)

      expect(eligible_results).to be_empty
    end

    it 'keeps failed messages of a circuit-open endpoint eligible' do
      endpoint.update!(circuit_state: :circuit_open)
      message = create(:message, project: project, endpoint: endpoint, status: :failed)

      expect(eligible_results.map(&:id)).to contain_exactly(message.id)
    end

    it 'excludes held failed messages' do
      message = create(:message, project: project, endpoint: endpoint, status: :failed)
      message.update_columns(held_at: Time.current, hold_reason: 'endpoint_circuit_open')

      expect(eligible_results).to be_empty
    end

    it 'excludes failed messages with an active replay item' do
      message = create(:message, project: project, endpoint: endpoint, status: :failed)
      create(:replay_item, message: message, endpoint: endpoint, status: ReplayItem::QUEUED_STATUS)

      expect(eligible_results).to be_empty
      expect(requested_results.map(&:id)).to contain_exactly(message.id)
    end

    it 'keeps failed messages whose previous replay terminated' do
      message = create(:message, project: project, endpoint: endpoint, status: :failed)
      create(:replay_item, message: message, endpoint: endpoint, status: ReplayItem::FAILED_STATUS)

      expect(eligible_results.map(&:id)).to contain_exactly(message.id)
    end

    it 'applies the endpoint filter' do
      other_endpoint = create(:endpoint, project: project)
      create(:message, project: project, endpoint: endpoint, status: :failed)
      create(:message, project: project, endpoint: other_endpoint, status: :failed)

      expect(eligible_results(endpoint_id: endpoint.id).map(&:endpoint_id)).to contain_exactly(endpoint.id)
    end

    it 'applies the event type filter' do
      create(:message, project: project, endpoint: endpoint, event: event, status: :failed)
      create(:message, project: project, endpoint: endpoint,
                       event: create(:event, project: project, event_type: 'payment.failed'), status: :failed)

      expect(eligible_results(event_type: 'order.created').map { |m| m.event.event_type })
        .to contain_exactly('order.created')
    end

    it 'excludes messages updated after the frozen instant' do
      frozen = Time.zone.local(2026, 1, 1, 12, 0, 0)
      before = create(:message, project: project, endpoint: endpoint, status: :failed)
      before.update_columns(updated_at: frozen - 1.minute)
      after = create(:message, project: project, endpoint: endpoint, status: :failed)
      after.update_columns(updated_at: frozen + 1.minute)

      expect(eligible_results(as_of: frozen).map(&:id)).to contain_exactly(before.id)
    end

    it 'does not leak messages of another project' do
      create(:message, project: project, endpoint: endpoint, status: :failed)
      create(:message, status: :failed)

      expect(eligible_results.size).to eq(1)
    end
  end

  describe '.count' do
    it 'counts without selecting the attempt summary columns' do
      create(:message, project: project, endpoint: endpoint, status: :failed)
      create(:message, project: project, endpoint: endpoint, status: :failed)

      expect(count).to eq(2)
      expect(count(eligible: false)).to eq(2)
    end
  end
end
