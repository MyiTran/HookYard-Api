class CreateEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :events, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :event_type, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :idempotency_key, null: false
      t.string :idempotency_fingerprint, null: false
      t.timestamps
    end

    add_index :events, %i[project_id idempotency_key], unique: true
    add_index :events, %i[project_id created_at]

    add_check_constraint :events, 'char_length(idempotency_key) BETWEEN 1 AND 255',
                         name: 'events_idempotency_key_length'
    add_check_constraint :events, "jsonb_typeof(payload) = 'object'", name: 'events_payload_is_object'
  end
end
