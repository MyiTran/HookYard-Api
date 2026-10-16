class AddArchiveSubscriptionsAndSigningSecretsToEndpoints < ActiveRecord::Migration[8.0]
  def change
    add_column :endpoints, :archived_at, :datetime
    add_index :endpoints, :archived_at

    add_column :endpoints, :event_types, :string, array: true, default: [], null: false
    add_check_constraint :endpoints, "NOT ('*' = ANY(event_types)) OR cardinality(event_types) = 1",
                         name: 'endpoints_wildcard_subscription_exclusive'

    create_table :endpoint_signing_secrets, id: :uuid do |t|
      t.references :endpoint, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :version, null: false
      t.text :secret, null: false
      t.timestamps
    end

    add_index :endpoint_signing_secrets, %i[endpoint_id version], unique: true
  end
end
