class AddPendingDeliveryIndexToMessages < ActiveRecord::Migration[8.0]
  def change
    add_index :messages, :updated_at,
              where: "status = 'pending'",
              name: 'index_messages_on_pending_updated_at'
  end
end
