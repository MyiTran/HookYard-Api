class RemovePlanFromProjects < ActiveRecord::Migration[8.0]
  def change
    remove_check_constraint :projects, name: 'projects_plan_valid'
    remove_column :projects, :plan, :string, null: false, default: 'free'
  end
end
