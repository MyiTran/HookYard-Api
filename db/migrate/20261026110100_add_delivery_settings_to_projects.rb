class AddDeliverySettingsToProjects < ActiveRecord::Migration[8.0]
  MAX_RETRY_DELAY_SLOTS = 7

  def change
    add_column :projects, :plan, :string, null: false, default: 'free'
    add_column :projects, :delivery_timeout_seconds, :integer
    add_column :projects, :delivery_retry_delays_seconds, :integer, array: true

    add_check_constraint :projects, "plan IN ('free', 'pro')", name: 'projects_plan_valid'
    add_check_constraint :projects,
                         'delivery_timeout_seconds IS NULL OR delivery_timeout_seconds BETWEEN 1 AND 30',
                         name: 'projects_delivery_timeout_seconds_range'
    add_check_constraint :projects,
                         'delivery_retry_delays_seconds IS NULL OR ' \
                         "(cardinality(delivery_retry_delays_seconds) BETWEEN 1 AND #{MAX_RETRY_DELAY_SLOTS})",
                         name: 'projects_delivery_retry_delays_size'
    add_check_constraint :projects,
                         'delivery_retry_delays_seconds IS NULL OR 0 < ALL(delivery_retry_delays_seconds)',
                         name: 'projects_delivery_retry_delays_positive'
  end
end
