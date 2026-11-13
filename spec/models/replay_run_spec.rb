require 'rails_helper'

describe ReplayRun, type: :model do
  let(:project) { create(:project, :with_owner) }
  let(:actor) { project.owner }
  let(:stream) { ProjectRealtimeChannel.stream_name(project.id) }

  before { clear_cable_messages(stream) }

  describe 'realtime broadcast' do
    it 'broadcasts a replay.changed event when the run is created' do
      run = described_class.create!(project: project, actor: actor)

      expect(cable_messages(stream)).to contain_exactly(
        include('type' => 'replay.changed', 'project_id' => project.id, 'replay_run_id' => run.id)
      )
    end

    it 'broadcasts when the run is materialized' do
      run = described_class.create!(project: project, actor: actor)
      clear_cable_messages(stream)

      run.update!(materialized_at: Time.current)

      expect(cable_messages(stream)).to contain_exactly(
        include('type' => 'replay.changed', 'project_id' => project.id, 'replay_run_id' => run.id)
      )
    end

    it 'does not broadcast on unrelated updates' do
      run = described_class.create!(project: project, actor: actor)
      clear_cable_messages(stream)

      run.update!(mode: described_class::MODE_BULK)

      expect(cable_messages(stream)).to be_empty
    end
  end
end
