require 'rails_helper'

describe ReplayCandidatesQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }

  def failed_message(target_endpoint = endpoint)
    create(:message, project: project, endpoint: target_endpoint, status: :failed)
  end

  describe '.call' do
    it 'returns only messages that terminally failed' do
      failed = failed_message
      create(:message, project: project, endpoint: endpoint, status: :succeeded)
      create(:message, project: project, endpoint: endpoint, status: :pending)

      expect(described_class.call(project_messages).to_a).to eq([failed])
    end

    it 'excludes messages of archived endpoints' do
      archived = create(:endpoint, project: project, archived_at: Time.current)
      failed_message(archived)

      expect(described_class.call(project_messages)).to be_empty
    end

    it 'excludes messages of paused endpoints' do
      paused = create(:endpoint, project: project, active: false)
      failed_message(paused)

      expect(described_class.call(project_messages)).to be_empty
    end

    it 'excludes messages of disabled endpoints' do
      disabled = create(:endpoint, project: project, circuit_state: :disabled)
      failed_message(disabled)

      expect(described_class.call(project_messages)).to be_empty
    end

    it 'keeps messages of endpoints whose circuit is open' do
      open_endpoint = create(:endpoint, project: project, circuit_state: :circuit_open)
      message = failed_message(open_endpoint)

      expect(described_class.call(project_messages).to_a).to eq([message])
    end

    it 'excludes messages that already have an active replay' do
      message = failed_message
      create(:replay_item, message: message)

      expect(described_class.call(project_messages)).to be_empty
    end

    it 'includes messages whose previous replay finished' do
      message = failed_message
      create(:replay_item, message: message, status: ReplayItem::FAILED_STATUS, completed_at: Time.current)

      expect(described_class.call(project_messages).to_a).to eq([message])
    end

    it 'keeps blocked messages when eligibility is not required' do
      disabled = create(:endpoint, project: project, circuit_state: :disabled)
      failed_message(disabled)

      expect(described_class.count(project_messages, eligible: false)).to eq(1)
    end

    it 'applies the delivery log filters' do
      other_endpoint = create(:endpoint, project: project)
      matching = failed_message
      failed_message(other_endpoint)

      expect(described_class.call(project_messages, endpoint_id: endpoint.id).to_a).to eq([matching])
    end

    it 'ignores non replayable filters like status' do
      failed_message

      expect(described_class.count(project_messages, status: 'succeeded')).to eq(1)
    end
  end

  describe '.for_project' do
    it 'returns the messages of the project events only' do
      matching = failed_message
      other_project = create(:project)
      create(:message, project: other_project, endpoint: create(:endpoint, project: other_project), status: :failed)

      expect(described_class.for_project(project)).to contain_exactly(matching)
    end
  end

  def project_messages
    Message.where(event_id: Event.where(project_id: project.id).select(:id))
  end
end
