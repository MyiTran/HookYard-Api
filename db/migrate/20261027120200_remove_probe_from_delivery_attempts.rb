class RemoveProbeFromDeliveryAttempts < ActiveRecord::Migration[8.0]
  # The column was added by an unreleased local migration for message-based
  # probes; synthetic circuit probes keep their evidence in circuit_probes.
  def change
    remove_column :delivery_attempts, :probe, :boolean, if_exists: true
  end
end
