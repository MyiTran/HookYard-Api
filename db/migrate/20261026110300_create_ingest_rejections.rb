class CreateIngestRejections < ActiveRecord::Migration[8.0]
  def change
    create_table :ingest_rejections, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :endpoint, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :reason, null: false
      t.string :event_type
      t.string :idempotency_key
      t.jsonb :payload, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :ingest_rejections, %i[project_id created_at]
  end
end
