class ReplayItemSerializer < ApplicationSerializer
  identifier :id

  fields :message_id, :endpoint_id, :status, :hold_reason, :skip_reason, :error_type, :error_message,
         :created_at, :started_at, :completed_at

  field :delivery_attempt_id do |item|
    item.delivery_attempt&.id
  end
end
