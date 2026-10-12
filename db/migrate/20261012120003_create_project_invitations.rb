class CreateProjectInvitations < ActiveRecord::Migration[8.0]
  def change
    create_table :project_invitations, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :invited_by, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :recipient, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :role, null: false, default: 'maintainer'
      t.string :status, null: false, default: 'pending'
      t.datetime :accepted_at
      t.datetime :cancelled_at
      t.timestamps
    end

    add_index :project_invitations, %i[project_id recipient_id], unique: true, where: "status = 'pending'",
                                                                  name: 'index_project_invitations_pending_recipient'
  end
end
