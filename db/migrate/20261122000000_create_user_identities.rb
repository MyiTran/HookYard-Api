class CreateUserIdentities < ActiveRecord::Migration[8.0]
  def change
    create_table :user_identities, id: :uuid do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :provider, null: false
      t.string :uid, null: false
      t.string :email_at_provider, null: false

      t.timestamps
    end

    add_index :user_identities, %i[provider uid], unique: true
    add_index :user_identities, %i[user_id provider], unique: true
  end
end
