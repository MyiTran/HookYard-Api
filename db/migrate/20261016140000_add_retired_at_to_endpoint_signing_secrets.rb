class AddRetiredAtToEndpointSigningSecrets < ActiveRecord::Migration[8.0]
  def up
    add_column :endpoint_signing_secrets, :retired_at, :datetime

    execute <<~SQL
      UPDATE endpoint_signing_secrets older
      SET retired_at = NOW()
      WHERE EXISTS (
        SELECT 1 FROM endpoint_signing_secrets newer
        WHERE newer.endpoint_id = older.endpoint_id AND newer.version > older.version
      )
    SQL

    add_index :endpoint_signing_secrets,
              :endpoint_id,
              unique: true,
              where: 'retired_at IS NULL',
              name: 'index_endpoint_signing_secrets_on_current_endpoint'
  end

  def down
    remove_index :endpoint_signing_secrets, name: 'index_endpoint_signing_secrets_on_current_endpoint'
    remove_column :endpoint_signing_secrets, :retired_at
  end
end
