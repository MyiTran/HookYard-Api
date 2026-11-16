class RemovePlanFromProjects < ActiveRecord::Migration[8.0]
  def change
    remove_column :projects, :plan, :string, null: false, default: 'free'
  end
end
