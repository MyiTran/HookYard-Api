class AddQuotaReservedAtToReplayItems < ActiveRecord::Migration[8.0]
  def change
    add_column :replay_items, :quota_reserved_at, :datetime
  end
end
