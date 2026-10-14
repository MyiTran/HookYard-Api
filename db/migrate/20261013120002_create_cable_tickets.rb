class CreateCableTickets < ActiveRecord::Migration[8.0]
  def change
    create_table :cable_tickets, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :token, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
    end

    add_index :cable_tickets, :token, unique: true
    add_index :cable_tickets, :expires_at
  end
end
