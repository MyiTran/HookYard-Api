class CreateProjectUsagePeriods < ActiveRecord::Migration[8.0]
  def change
    create_table :project_usage_periods, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.date :period_starts_on, null: false
      t.integer :deliveries_count, null: false, default: 0
      t.timestamps
    end

    add_index :project_usage_periods, %i[project_id period_starts_on], unique: true
    add_check_constraint :project_usage_periods,
                         'deliveries_count >= 0',
                         name: 'project_usage_periods_deliveries_count_non_negative'
    add_check_constraint :project_usage_periods,
                         'EXTRACT(DAY FROM period_starts_on) = 1',
                         name: 'project_usage_periods_period_starts_on_first_of_month'
  end
end
