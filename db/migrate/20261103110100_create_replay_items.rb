class CreateReplayItems < ActiveRecord::Migration[8.0]
  def change
    create_table :replay_items, id: :uuid do |t|
      t.references :replay_run, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :message, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :endpoint, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: 'queued'
      t.string :hold_reason
      t.string :skip_reason
      t.string :error_type
      t.text :error_message
      t.datetime :delivery_lease_expires_at
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :replay_items, %i[replay_run_id status]
    add_index :replay_items, %i[endpoint_id status]
    add_index :replay_items, :message_id,
              unique: true,
              where: "status IN ('queued', 'held', 'delivering')",
              name: 'index_replay_items_on_active_message'
    add_check_constraint :replay_items,
                         "status IN ('queued', 'held', 'delivering', 'succeeded', 'failed', 'skipped')",
                         name: 'replay_items_status_valid'
  end
end
