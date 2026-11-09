class AddDeliverySettingsToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :plan, :string, null: false, default: 'free'
    add_column :projects, :delivery_timeout_seconds, :integer
    add_column :projects, :delivery_retry_delays_seconds, :integer, array: true
  end
end
