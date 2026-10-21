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
require 'ipaddr'

class Endpoint < ApplicationRecord
  SIGNING_SECRET_BYTES = 32
  WILDCARD_EVENT_TYPE = '*'

  INTERNAL_HOSTNAMES = %w[localhost localhost.localdomain ip6-localhost ip6-loopback].freeze
  INTERNAL_HOSTNAME_SUFFIXES = %w[.localhost .local .internal .localdomain .home.arpa .lan .corp .home].freeze
  PUBLIC_HOSTNAME = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  NON_PUBLIC_IPV4_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16
    198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
  ].map { |range| IPAddr.new(range) }.freeze

  NON_PUBLIC_IPV6_RANGES = %w[
    ::/128 ::1/128 64:ff9b::/96 100::/64 2001:db8::/32
    ::ffff:0:0/96 fc00::/7 fe80::/10 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

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
    uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? && public_host?(uri.host)
  end

  def public_host?(host)
    normalized_host = host.downcase.delete_suffix('.')
    return public_ip_literal?(normalized_host[1..-2]) if bracketed_ipv6?(normalized_host)
    return public_ip_literal?(normalized_host) if canonical_ipv4?(normalized_host)
    return false if ambiguous_numeric_host?(normalized_host)

    public_hostname?(normalized_host)
  end

  def bracketed_ipv6?(host)
    host.start_with?('[') && host.end_with?(']')
  end

  def canonical_ipv4?(host)
    labels = host.split('.')
    labels.size == 4 && labels.all? { |label| canonical_ipv4_label?(label) }
  end

  def canonical_ipv4_label?(label)
    label.match?(/\A(0|[1-9]\d{0,2})\z/) && label.to_i <= 255
  end

  def ambiguous_numeric_host?(host)
    host.match?(/\A[\d.]+\z/) || host.match?(/\.\d+\z/)
  end

  def public_ip_literal?(value)
    !non_public_ip?(IPAddr.new(value))
  rescue IPAddr::Error
    false
  end

  def non_public_ip?(ip)
    ranges = ip.ipv4? ? NON_PUBLIC_IPV4_RANGES : NON_PUBLIC_IPV6_RANGES
    ranges.any? { |range| range.include?(ip) }
  end

  def public_hostname?(host)
    return false unless host.match?(PUBLIC_HOSTNAME)
    return false if INTERNAL_HOSTNAMES.include?(host)

    INTERNAL_HOSTNAME_SUFFIXES.none? { |suffix| host.end_with?(suffix) }
  end
end
