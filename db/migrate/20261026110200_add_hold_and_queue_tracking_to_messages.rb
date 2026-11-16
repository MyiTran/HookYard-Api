class AddHoldAndQueueTrackingToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :queued_at, :datetime
    add_column :messages, :held_at, :datetime
    add_column :messages, :hold_reason, :string

    add_index :messages, %i[endpoint_id held_at], name: 'index_messages_on_endpoint_id_and_held_at'
  end
end
