class CreateCircuitProbes < ActiveRecord::Migration[8.0]
  def change
    create_table :circuit_probes, id: :uuid do |t|
      t.references :endpoint, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :request_id, null: false
      t.string :webhook_id, null: false
      t.integer :signing_secret_version
      t.string :status, null: false, default: 'pending'
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.text :request_url, null: false
      t.text :request_body, null: false
      t.integer :response_status
      t.jsonb :response_headers
      t.text :response_body
      t.integer :duration_ms
      t.string :error_type
      t.text :error_message
      t.timestamps

      t.index %i[endpoint_id created_at]
      t.index %i[endpoint_id status]
      t.check_constraint "status IN ('pending', 'succeeded', 'failed')", name: 'circuit_probes_status_check'
    end
  end
end
