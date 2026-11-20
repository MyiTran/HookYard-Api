class AddUnrecordedDeliveryMetricsIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :delivery_attempts, :id,
              where: 'metrics_recorded_at IS NULL',
              name: 'index_delivery_attempts_on_unrecorded_metrics',
              algorithm: :concurrently
  end

  def down
    remove_index :delivery_attempts,
                 name: 'index_delivery_attempts_on_unrecorded_metrics',
                 algorithm: :concurrently
  end
end
