class AddCircuitBreakerFieldsToEndpoints < ActiveRecord::Migration[8.0]
  def change
    add_column :endpoints, :circuit_state, :string, null: false, default: 'enabled'
    add_column :endpoints, :circuit_failure_count, :integer, null: false, default: 0
    add_column :endpoints, :circuit_opened_at, :datetime
    add_column :endpoints, :circuit_next_probe_at, :datetime
    add_column :endpoints, :circuit_probe_lease_expires_at, :datetime
    add_column :endpoints, :queued_message_count, :integer, null: false, default: 0

    add_check_constraint :endpoints, "circuit_state IN ('enabled', 'circuit_open', 'disabled')",
                         name: 'endpoints_circuit_state_valid'
    add_check_constraint :endpoints, 'circuit_failure_count >= 0',
                         name: 'endpoints_circuit_failure_count_non_negative'
    add_check_constraint :endpoints, 'queued_message_count >= 0',
                         name: 'endpoints_queued_message_count_non_negative'

    add_index :endpoints, %i[circuit_state circuit_next_probe_at],
              name: 'index_endpoints_on_circuit_state_and_next_probe_at'
  end
end
