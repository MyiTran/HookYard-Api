class AddCircuitBreakerFieldsToEndpoints < ActiveRecord::Migration[8.0]
  def change
    add_column :endpoints, :circuit_state, :string, null: false, default: 'enabled'
    add_column :endpoints, :circuit_failure_count, :integer, null: false, default: 0
    add_column :endpoints, :circuit_opened_at, :datetime
    add_column :endpoints, :circuit_next_probe_at, :datetime
    add_column :endpoints, :circuit_probe_lease_expires_at, :datetime
    add_column :endpoints, :queued_message_count, :integer, null: false, default: 0

    add_index :endpoints, %i[circuit_state circuit_next_probe_at],
              name: 'index_endpoints_on_circuit_state_and_next_probe_at'
  end
end
