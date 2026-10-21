# == Schema Information
#
# Table name: delivery_attempts
#
#  id                     :uuid             not null, primary key
#  attempt_number         :integer          default(1), not null
#  duration_ms            :integer
#  error_message          :text
#  error_type             :string
#  http_method            :string           default("POST"), not null
#  request_body           :text             not null
#  request_headers        :jsonb            not null
#  request_url            :text             not null
#  response_body          :text
#  response_headers       :jsonb
#  response_status        :integer
#  signed_at              :datetime         not null
#  signing_secret_version :integer          not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  message_id             :uuid             not null
#  request_id             :string           not null
#  webhook_id             :string           not null
#
# Indexes
#
#  index_delivery_attempts_on_message_id                     (message_id)
#  index_delivery_attempts_on_message_id_and_attempt_number  (message_id,attempt_number) UNIQUE
#  index_delivery_attempts_on_message_id_and_created_at      (message_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (message_id => messages.id) ON DELETE => cascade
#
class DeliveryAttempt < ApplicationRecord
  RESPONSE_BODY_MAX_BYTES = 4096
  ERROR_MESSAGE_MAX_BYTES = 1024
  SENSITIVE_HEADERS = %w[set-cookie cookie authorization proxy-authenticate www-authenticate].freeze
  EVIDENCE_FIELDS = %i[
    message_id attempt_number request_id webhook_id signing_secret_version signed_at
    request_url http_method request_headers request_body
  ].freeze

  belongs_to :message

  validates :attempt_number, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :attempt_number, uniqueness: { scope: :message_id }
  validates :request_id, :webhook_id, :request_url, :http_method, :request_body, presence: true
  validates :signing_secret_version, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :signed_at, presence: true
  validate :evidence_is_immutable, on: :update

  def self.truncate_response_body(body)
    return nil if body.nil?

    body.to_s.byteslice(0, RESPONSE_BODY_MAX_BYTES).to_s.scrub
  end

  def self.truncate_error_message(message)
    return nil if message.nil?

    message.to_s.byteslice(0, ERROR_MESSAGE_MAX_BYTES).to_s.scrub
  end

  def self.filter_headers(headers)
    headers.to_h.stringify_keys.except(*SENSITIVE_HEADERS)
  end

  def succeeded?
    response_status.present? && response_status.between?(200, 299)
  end

  def transport_failed?
    error_type.present?
  end

  private

  def evidence_is_immutable
    return unless EVIDENCE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }

    errors.add(:base, 'delivery evidence can not be modified')
  end
end
