class AddMetricsRecordedAtToDeliveryAttempts < ActiveRecord::Migration[8.0]
  def change
    add_column :delivery_attempts, :metrics_recorded_at, :datetime
  end
end
