class CreateMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :messages, id: :uuid do |t|
      t.references :event, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :endpoint, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :status, null: false, default: 'pending'
      t.timestamps
    end

    add_index :messages, %i[event_id endpoint_id], unique: true
    add_index :messages, %i[endpoint_id created_at]

    add_check_constraint :messages,
                         "status IN ('pending', 'delivering', 'succeeded', 'failed')",
                         name: 'messages_status_valid'
  end
end
