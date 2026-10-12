class CreateProjectMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :project_memberships, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false
      t.timestamps
    end

    add_index :project_memberships, %i[project_id user_id], unique: true
    add_index :project_memberships, :project_id, unique: true, where: "role = 'owner'",
                                                 name: 'index_project_memberships_on_project_id_owner'
  end
end
