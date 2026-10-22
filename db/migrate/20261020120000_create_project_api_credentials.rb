class CreateProjectApiCredentials < ActiveRecord::Migration[8.0]
  def change
    create_table :project_api_credentials, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_hint, null: false
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :project_api_credentials, :token_digest, unique: true
  end
end
