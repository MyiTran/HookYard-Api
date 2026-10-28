# == Schema Information
#
# Table name: endpoints
#
#  id          :uuid             not null, primary key
#  active      :boolean          default(TRUE), not null
#  archived_at :datetime
#  description :text
#  event_types :string           default([]), not null, is an Array
#  name        :string           not null
#  url         :string           not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  project_id  :uuid             not null
#
# Indexes
#
#  index_endpoints_on_archived_at  (archived_at)
#  index_endpoints_on_project_id   (project_id)
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class Endpoint < ApplicationRecord
  SIGNING_SECRET_BYTES = 32
  WILDCARD_EVENT_TYPE = '*'

  belongs_to :project
  has_many :endpoint_signing_secrets, dependent: :destroy
  has_many :messages, dependent: :destroy

  scope :archived, -> { where.not(archived_at: nil) }
  scope :not_archived, -> { where(archived_at: nil) }

  validates :name, presence: true
  validates :url, presence: true
  validate :url_must_be_http
  validate :event_types_must_be_consistent

  def archived?
    archived_at.present?
  end

  def subscribed_to?(event_type)
    event_types.include?(WILDCARD_EVENT_TYPE) || event_types.include?(event_type)
  end

  def current_signing_secret
    endpoint_signing_secrets.find { |secret| secret.retired_at.nil? }
  end

  def signing_secret_version
    current_signing_secret&.version
  end

  def has_signing_secret?
    endpoint_signing_secrets.any?
  end

  def rotate_signing_secret!
    with_lock do
      current_signing_secret&.update!(retired_at: Time.current)
      endpoint_signing_secrets.create!(version: next_signing_secret_version, secret: new_signing_secret)
    end
  end

  private

  def next_signing_secret_version
    (endpoint_signing_secrets.maximum(:version) || 0) + 1
  end

  def new_signing_secret
    "whsec_#{Base64.strict_encode64(SecureRandom.random_bytes(SIGNING_SECRET_BYTES))}"
  end

  def event_types_must_be_consistent
    return if event_types.blank?

    errors.add(:event_types, 'cannot contain blank event types') if event_types.any? { |type| type.to_s.strip.blank? }
    errors.add(:event_types, 'cannot contain duplicates') if event_types.uniq.length != event_types.length
    return unless event_types.include?(WILDCARD_EVENT_TYPE) && event_types.length > 1

    errors.add(:event_types, "cannot combine '#{WILDCARD_EVENT_TYPE}' with specific event types")
  end

  def url_must_be_http
    return if url.blank?

    uri = URI.parse(url)
    errors.add(:url, 'must be a public HTTP(S) URL') unless public_http_url?(uri)
  rescue URI::Error
    errors.add(:url, 'must be a valid HTTP(S) URL')
  end

  def public_http_url?(uri)
    uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && Webhooks::DestinationPolicy.public_host?(uri.host)
  end
end
