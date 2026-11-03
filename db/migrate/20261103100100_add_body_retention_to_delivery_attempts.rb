class AddBodyRetentionToDeliveryAttempts < ActiveRecord::Migration[8.0]
  def change
    add_column :delivery_attempts, :bodies_purged_at, :datetime
    change_column_null :delivery_attempts, :request_body, true
    add_index :delivery_attempts, :created_at,
              where: 'bodies_purged_at IS NULL AND (response_status IS NOT NULL OR error_type IS NOT NULL)',
              name: 'index_delivery_attempts_on_bodies_pending_purge'
  end
end
