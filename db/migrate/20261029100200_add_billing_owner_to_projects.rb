class AddBillingOwnerToProjects < ActiveRecord::Migration[8.0]
  def change
    add_column :projects, :billing_owner_id, :uuid
    add_index :projects, :billing_owner_id
  end
end
