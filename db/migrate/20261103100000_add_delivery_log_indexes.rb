class AddDeliveryLogIndexes < ActiveRecord::Migration[8.0]
  def change
    add_index :delivery_attempts, :request_id, name: 'index_delivery_attempts_on_request_id'
    add_index :messages, %i[created_at id], name: 'index_messages_on_created_at_and_id'
    add_index :events, :event_type, name: 'index_events_on_event_type'
    add_index :ingest_rejections, %i[created_at id], name: 'index_ingest_rejections_on_created_at_and_id'
  end
end
