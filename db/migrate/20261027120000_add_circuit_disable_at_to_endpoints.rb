class AddCircuitDisableAtToEndpoints < ActiveRecord::Migration[8.0]
  # Rows opened before the deadline was persisted can only be backfilled with the
  # production default window; the effective window they opened under is not stored.
  LEGACY_DISABLE_WINDOW = '5 days'.freeze

  def up
    add_column :endpoints, :circuit_disable_at, :datetime

    execute <<~SQL.squish
      UPDATE endpoints
      SET circuit_disable_at = circuit_opened_at + INTERVAL '#{LEGACY_DISABLE_WINDOW}'
      WHERE circuit_opened_at IS NOT NULL
    SQL
  end

  def down
    remove_column :endpoints, :circuit_disable_at
  end
end
