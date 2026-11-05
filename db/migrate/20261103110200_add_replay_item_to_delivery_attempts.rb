class AddReplayItemToDeliveryAttempts < ActiveRecord::Migration[8.0]
  def change
    add_reference :delivery_attempts, :replay_item,
                  type: :uuid,
                  null: true,
                  index: { unique: true },
                  foreign_key: { on_delete: :nullify }
  end
end
