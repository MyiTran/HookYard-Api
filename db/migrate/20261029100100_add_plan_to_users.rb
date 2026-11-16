class AddPlanToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :plan, :string, null: false, default: 'free'
    add_check_constraint :users, "plan IN ('free', 'pro')", name: 'users_plan_valid'
  end
end
