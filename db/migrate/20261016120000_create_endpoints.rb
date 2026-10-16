class CreateEndpoints < ActiveRecord::Migration[8.0]
  def change
    create_table :endpoints, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.string :url, null: false
      t.text :description
      t.boolean :active, null: false, default: true
      t.timestamps
    end
  end
end
