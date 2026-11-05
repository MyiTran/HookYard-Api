class CreateEndpointDiagnoses < ActiveRecord::Migration[8.0]
  LABELS = %w[
    signature_mismatch auth_expired endpoint_moved handler_timeout payload_rejected
    rate_limited tls_failure endpoint_gone unknown
  ].freeze

  def change
    create_table :endpoint_diagnoses, id: :uuid do |t|
      t.references :endpoint, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :requested_by, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :label, null: false
      t.text :suggested_action, null: false
      t.string :source, null: false
      t.string :model
      t.integer :analyzed_attempt_count, null: false, default: 0
      t.timestamps
    end

    add_index :endpoint_diagnoses, %i[endpoint_id created_at]
    add_index :endpoint_diagnoses, %i[project_id created_at]
    add_check_constraint :endpoint_diagnoses,
                         "source IN ('ai', 'fallback')",
                         name: 'endpoint_diagnoses_source_valid'
    add_check_constraint :endpoint_diagnoses,
                         "label IN (#{LABELS.map { |label| "'#{label}'" }.join(', ')})",
                         name: 'endpoint_diagnoses_label_valid'
    add_check_constraint :endpoint_diagnoses,
                         'analyzed_attempt_count >= 0',
                         name: 'endpoint_diagnoses_attempt_count_non_negative'
  end
end
