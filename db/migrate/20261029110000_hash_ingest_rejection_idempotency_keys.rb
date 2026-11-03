class HashIngestRejectionIdempotencyKeys < ActiveRecord::Migration[8.0]
  def up
    add_column :ingest_rejections, :idempotency_key_digest, :string

    execute <<~SQL.squish
      UPDATE ingest_rejections
      SET idempotency_key_digest = encode(digest(idempotency_key, 'sha256'), 'hex')
      WHERE idempotency_key IS NOT NULL
    SQL

    remove_column :ingest_rejections, :idempotency_key
  end

  def down
    add_column :ingest_rejections, :idempotency_key, :string
    remove_column :ingest_rejections, :idempotency_key_digest
  end
end
