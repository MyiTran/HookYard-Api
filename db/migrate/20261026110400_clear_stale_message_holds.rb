class ClearStaleMessageHolds < ActiveRecord::Migration[8.0]
  CONSTRAINT_NAME = 'messages_hold_requires_pending'.freeze

  def up
    execute <<~SQL.squish
      UPDATE messages
      SET held_at = NULL, hold_reason = NULL, updated_at = NOW()
      WHERE status <> 'pending' AND (held_at IS NOT NULL OR hold_reason IS NOT NULL)
    SQL

    add_check_constraint :messages,
                         "status = 'pending' OR (held_at IS NULL AND hold_reason IS NULL)",
                         name: CONSTRAINT_NAME
  end

  def down
    remove_check_constraint :messages, name: CONSTRAINT_NAME
  end
end
