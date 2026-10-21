# == Schema Information
#
# Table name: messages
#
#  id          :uuid             not null, primary key
#  status      :string           default("pending"), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  endpoint_id :uuid             not null
#  event_id    :uuid             not null
#
# Indexes
#
#  index_messages_on_endpoint_id                 (endpoint_id)
#  index_messages_on_endpoint_id_and_created_at  (endpoint_id,created_at)
#  index_messages_on_event_id                    (event_id)
#  index_messages_on_event_id_and_endpoint_id    (event_id,endpoint_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#  fk_rails_...  (event_id => events.id) ON DELETE => cascade
#
class Message < ApplicationRecord
  PENDING_STATUS = 'pending'

  attribute :attempt_count, :integer
  attribute :last_attempt_at, :datetime
  attribute :last_response_status, :integer
  attribute :last_duration_ms, :integer
  attribute :last_error_type, :string

  enum :status, { pending: PENDING_STATUS, delivering: 'delivering', succeeded: 'succeeded', failed: 'failed' },
       default: :pending, validate: true

  belongs_to :event
  belongs_to :endpoint
  has_many :delivery_attempts, -> { order(:attempt_number) }, dependent: :destroy

  def webhook_id
    "msg_#{id}"
  end
end
