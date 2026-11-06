class AddProbeToDeliveryAttempts < ActiveRecord::Migration[8.0]
  def change
    add_column :delivery_attempts, :probe, :boolean, null: false, default: false
  end
end
