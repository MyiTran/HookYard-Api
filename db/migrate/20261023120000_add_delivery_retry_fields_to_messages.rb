class AddDeliveryRetryFieldsToMessages < ActiveRecord::Migration[8.0]
  def up
    add_column :messages, :attempt_count, :integer, null: false, default: 0
    add_column :messages, :next_retry_at, :datetime
    add_column :messages, :delivery_lease_expires_at, :datetime
    add_column :messages, :terminal_at, :datetime

    add_check_constraint :messages, 'attempt_count >= 0', name: 'messages_attempt_count_non_negative'

    add_index :messages, %i[status next_retry_at], name: 'index_messages_on_status_and_next_retry_at'
    add_index :messages, %i[endpoint_id status delivery_lease_expires_at],
              name: 'index_messages_on_endpoint_status_and_lease'
    add_index :messages, :delivery_lease_expires_at,
              where: "status = 'delivering'",
              name: 'index_messages_on_active_delivery_lease'
  end

  def down
    remove_index :messages, name: 'index_messages_on_active_delivery_lease'
    remove_index :messages, name: 'index_messages_on_endpoint_status_and_lease'
    remove_index :messages, name: 'index_messages_on_status_and_next_retry_at'

    remove_check_constraint :messages, name: 'messages_attempt_count_non_negative'

    remove_column :messages, :terminal_at
    remove_column :messages, :delivery_lease_expires_at
    remove_column :messages, :next_retry_at
    remove_column :messages, :attempt_count
  end
end
