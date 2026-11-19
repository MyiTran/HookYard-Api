class AddSnapshotAndFailureStateToReplayRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :replay_runs, :as_of, :datetime
    add_column :replay_runs, :failed_at, :datetime
    add_column :replay_runs, :failure_reason, :string
  end
end
