class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :project, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :project_invitation, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.string :title, null: false
      t.string :message, null: false
      t.string :target_url
      t.datetime :read_at
      t.timestamps
    end

    add_index :notifications, %i[user_id created_at]
  end
end
