class AddBillingOwnerToProjects < ActiveRecord::Migration[8.0]
  def up
    add_column :projects, :billing_owner_id, :uuid
    add_index :projects, :billing_owner_id

    backfill_billing_owner_from_project_owner!
    ensure_every_project_has_billing_owner!

    change_column_null :projects, :billing_owner_id, false
    add_foreign_key :projects, :users, column: :billing_owner_id, on_delete: :restrict
  end

  def down
    remove_foreign_key :projects, column: :billing_owner_id
    remove_index :projects, :billing_owner_id
    remove_column :projects, :billing_owner_id
  end

  private

  # The unique partial index on owner memberships guarantees at most one owner per project,
  # so the backfill never has to pick between several candidate owners.
  def backfill_billing_owner_from_project_owner!
    execute(<<~SQL.squish)
      UPDATE projects
      SET billing_owner_id = owner_memberships.user_id
      FROM project_memberships AS owner_memberships
      WHERE owner_memberships.project_id = projects.id
        AND owner_memberships.role = 'owner'
    SQL
  end

  def ensure_every_project_has_billing_owner!
    unresolved_project_ids = select_values('SELECT id FROM projects WHERE billing_owner_id IS NULL')
    return if unresolved_project_ids.empty?

    raise ActiveRecord::MigrationError, <<~MESSAGE
      Cannot derive a billing owner for projects: #{unresolved_project_ids.join(', ')}.
      They have no owner membership, so assigning one would be arbitrary. Give each project an owner
      membership (or set its billing_owner_id explicitly) and re-run this migration.
    MESSAGE
  end
end
