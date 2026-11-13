require 'rails_helper'

describe ReplayItem, type: :model do
  let(:project) { create(:project, :with_owner) }
  let!(:message) { create(:message, project: project) }
  let!(:run) { ReplayRun.create!(project: project, actor: project.owner) }
  let!(:item) { described_class.create!(replay_run: run, message: message, endpoint: message.endpoint) }
  let(:stream) { ProjectRealtimeChannel.stream_name(project.id) }

  before { clear_cable_messages(stream) }

  describe 'realtime broadcast' do
    it 'broadcasts a replay.changed event when the item status changes' do
      item.mark_succeeded!

      expect(cable_messages(stream)).to contain_exactly(
        include(
          'type' => 'replay.changed',
          'project_id' => project.id,
          'replay_run_id' => run.id,
          'replay_item_id' => item.id,
          'endpoint_id' => message.endpoint_id,
          'message_id' => message.id
        )
      )
    end

    it 'does not broadcast when only non-status fields change' do
      item.update!(delivery_lease_expires_at: 1.minute.from_now)

      expect(cable_messages(stream)).to be_empty
    end
  end
end
