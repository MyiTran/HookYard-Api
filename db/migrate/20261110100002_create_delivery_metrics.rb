class CreateDeliveryMetrics < ActiveRecord::Migration[8.0]
  def change
    create_table :delivery_metrics, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.date :day, null: false
      t.integer :attempts_count, null: false, default: 0
      t.integer :successes_count, null: false, default: 0
      t.integer :failures_count, null: false, default: 0
      t.timestamps
    end

    add_index :delivery_metrics, %i[project_id day], unique: true
  end
end
