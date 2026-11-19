class CreateReplayRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :replay_runs, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :mode, null: false, default: 'single'
      t.jsonb :filters, null: false, default: {}
      t.integer :requested_count, null: false, default: 0
      t.datetime :materialized_at
      t.timestamps
    end

    add_index :replay_runs, %i[project_id created_at]
    add_check_constraint :replay_runs, "mode IN ('single', 'bulk')", name: 'replay_runs_mode_valid'
    add_check_constraint :replay_runs, 'requested_count >= 0', name: 'replay_runs_requested_count_non_negative'
  end
end
