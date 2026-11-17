class AddIdempotencyKeyDigestToIngestRejections < ActiveRecord::Migration[8.0]
  def change
    add_column :ingest_rejections, :idempotency_key_digest, :string
  end
end
