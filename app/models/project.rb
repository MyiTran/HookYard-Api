# == Schema Information
#
# Table name: projects
#
#  id                            :uuid             not null, primary key
#  delivery_retry_delays_seconds :integer          is an Array
#  delivery_timeout_seconds      :integer
#  name                          :string           not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#  billing_owner_id              :uuid             not null
#
# Indexes
#
#  index_projects_on_billing_owner_id  (billing_owner_id)
#
# Foreign Keys
#
#  fk_rails_...  (billing_owner_id => users.id) ON DELETE => restrict
#
class Project < ApplicationRecord
  MAX_RETRY_DELAY_SLOTS = Webhooks::DeliveryPolicy::DEFAULT_RETRY_DELAYS.size

  belongs_to :billing_owner, class_name: 'User', inverse_of: :owned_projects

  has_many :project_memberships, dependent: :destroy
  has_many :project_invitations, dependent: :destroy
  has_many :project_api_credentials, dependent: :destroy
  has_many :events, dependent: :destroy
  has_many :endpoints, dependent: :destroy
  has_many :ingest_rejections, dependent: :destroy
  has_many :users, through: :project_memberships

  validates :name, presence: true
  validates :delivery_timeout_seconds,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: Webhooks::DeliveryPolicy::MIN_HTTP_TIMEOUT_SECONDS,
              less_than_or_equal_to: Webhooks::DeliveryPolicy::MAX_HTTP_TIMEOUT_SECONDS
            },
            allow_nil: true
  validate :delivery_overrides_require_pro_plan
  validate :retry_delays_must_be_positive_integers

  delegate :plan, to: :billing_owner, allow_nil: true

  def pro?
    plan == User::PRO_PLAN
  end

  def member?(user)
    return false if user.nil?

    project_memberships.exists?(user_id: user.id)
  end

  def endpoint_count
    endpoints.not_archived.count
  end

  def plan_locked_endpoint_ids
    endpoints.not_archived.order(:created_at, :id).offset(Plans::Entitlements.endpoint_limit(billing_owner)).pluck(:id)
  end

  def owner
    project_memberships.find_by(role: :owner)&.user
  end

  def owner?(user)
    return false if user.nil?

    project_memberships.exists?(user_id: user.id, role: :owner)
  end

  private

  def delivery_overrides_require_pro_plan
    return if pro?
    return if delivery_timeout_seconds.nil? && delivery_retry_delays_seconds.nil?

    errors.add(:base, 'the free plan cannot override the delivery policy')
  end

  def retry_delays_must_be_positive_integers
    return if delivery_retry_delays_seconds.nil?

    delays = delivery_retry_delays_seconds
    unless delays.is_a?(Array) && delays.length.between?(1, MAX_RETRY_DELAY_SLOTS) &&
           delays.all? { |delay| delay.is_a?(Integer) && delay.positive? }

      errors.add(:delivery_retry_delays_seconds, 'must be a non-empty list of positive seconds')
    end
  end
end
