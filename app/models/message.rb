# == Schema Information
#
# Table name: messages
#
#  id                        :uuid             not null, primary key
#  attempt_count             :integer          default(0), not null
#  delivery_lease_expires_at :datetime
#  next_retry_at             :datetime
#  status                    :string           default("pending"), not null
#  terminal_at               :datetime
#  created_at                :datetime         not null
#  updated_at                :datetime         not null
#  endpoint_id               :uuid             not null
#  event_id                  :uuid             not null
#
# Indexes
#
#  index_messages_on_active_delivery_lease       (delivery_lease_expires_at) WHERE ((status)::text = 'delivering'::text)
#  index_messages_on_endpoint_id                 (endpoint_id)
#  index_messages_on_endpoint_id_and_created_at  (endpoint_id,created_at)
#  index_messages_on_endpoint_status_and_lease   (endpoint_id,status,delivery_lease_expires_at)
#  index_messages_on_event_id                    (event_id)
#  index_messages_on_event_id_and_endpoint_id    (event_id,endpoint_id) UNIQUE
#  index_messages_on_pending_updated_at          (updated_at) WHERE ((status)::text = 'pending'::text)
#  index_messages_on_status_and_next_retry_at    (status,next_retry_at)
#
# Foreign Keys
#
#  fk_rails_...  (endpoint_id => endpoints.id) ON DELETE => cascade
#  fk_rails_...  (event_id => events.id) ON DELETE => cascade
#
class Message < ApplicationRecord
  include DeliveryLifecycle

  PENDING_STATUS = 'pending'

  attribute :last_attempt_at, :datetime
  attribute :last_response_status, :integer
  attribute :last_duration_ms, :integer
  attribute :last_error_type, :string

  enum :status, { pending: PENDING_STATUS, delivering: 'delivering', succeeded: 'succeeded', failed: 'failed' },
       default: :pending, validate: true

  belongs_to :event
  belongs_to :endpoint
  has_many :delivery_attempts, -> { order(:attempt_number) }, dependent: :destroy

  validate :event_and_endpoint_share_project

  def webhook_id
    "msg_#{id}"
  end

  private

  def event_and_endpoint_share_project
    return if event.nil? || endpoint.nil? || event.project_id == endpoint.project_id

    errors.add(:base, 'message event and endpoint must belong to the same project')
  end
end
