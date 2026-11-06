class AddHoldAndQueueTrackingToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :queued_at, :datetime
    add_column :messages, :held_at, :datetime
    add_column :messages, :hold_reason, :string

    add_check_constraint :messages,
                         "hold_reason IS NULL OR hold_reason IN ('endpoint_circuit_open', 'endpoint_disabled')",
                         name: 'messages_hold_reason_valid'

    add_index :messages, %i[endpoint_id held_at], name: 'index_messages_on_endpoint_id_and_held_at'

    execute <<~SQL.squish
      UPDATE endpoints
      SET queued_message_count = COALESCE(
        (SELECT COUNT(*) FROM messages
         WHERE messages.endpoint_id = endpoints.id AND messages.status IN ('pending', 'delivering')),
        0
      )
    SQL

    execute <<~SQL.squish
      UPDATE messages
      SET queued_at = COALESCE(messages.created_at, NOW())
      WHERE messages.status IN ('pending', 'delivering')
    SQL
  end
end
