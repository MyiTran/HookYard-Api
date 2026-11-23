class AddBillingOwnerForeignKeyToProjects < ActiveRecord::Migration[8.0]
  def change
    add_foreign_key :projects, :users,
                    column: :billing_owner_id,
                    on_delete: :restrict,
                    validate: false,
                    if_not_exists: true
  end
end
