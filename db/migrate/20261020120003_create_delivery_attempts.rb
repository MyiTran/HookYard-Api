class CreateDeliveryAttempts < ActiveRecord::Migration[8.0]
  def change
    create_table :delivery_attempts, id: :uuid do |t|
      t.references :message, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :attempt_number, null: false, default: 1
      t.string :request_id, null: false
      t.string :webhook_id, null: false
      t.integer :signing_secret_version, null: false
      t.datetime :signed_at, null: false
      t.text :request_url, null: false
      t.string :http_method, null: false, default: 'POST'
      t.jsonb :request_headers, null: false, default: {}
      t.text :request_body, null: false
      t.integer :response_status
      t.jsonb :response_headers
      t.text :response_body
      t.integer :duration_ms
      t.string :error_type
      t.text :error_message
      t.timestamps
    end

    add_index :delivery_attempts, %i[message_id attempt_number], unique: true
    add_index :delivery_attempts, %i[message_id created_at]

    add_check_constraint :delivery_attempts, 'signing_secret_version > 0',
                         name: 'delivery_attempts_signing_secret_version_positive'
    add_check_constraint :delivery_attempts,
                         'response_status IS NULL OR response_status BETWEEN 100 AND 599',
                         name: 'delivery_attempts_response_status_range'
  end
end
