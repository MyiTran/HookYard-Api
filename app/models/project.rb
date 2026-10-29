# == Schema Information
#
# Table name: projects
#
#  id                            :uuid             not null, primary key
#  delivery_retry_delays_seconds :integer          is an Array
#  delivery_timeout_seconds      :integer
#  name                          :string           not null
#  plan                          :string           default("free"), not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
#
class Project < ApplicationRecord
  FREE_PLAN = 'free'
  PRO_PLAN = 'pro'
  PLANS = [FREE_PLAN, PRO_PLAN].freeze
  MAX_RETRY_DELAY_SLOTS = Webhooks::DeliveryPolicy::DEFAULT_RETRY_DELAYS.size

  has_many :project_memberships, dependent: :destroy
  has_many :project_invitations, dependent: :destroy
  has_many :project_api_credentials, dependent: :destroy
  has_many :events, dependent: :destroy
  has_many :endpoints, dependent: :destroy
  has_many :ingest_rejections, dependent: :destroy
  has_many :usage_periods, class_name: 'ProjectUsagePeriod', dependent: :destroy
  has_many :users, through: :project_memberships

  validates :name, presence: true
  validates :plan, inclusion: { in: PLANS }
  validates :delivery_timeout_seconds,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: Webhooks::DeliveryPolicy::MIN_HTTP_TIMEOUT_SECONDS,
              less_than_or_equal_to: Webhooks::DeliveryPolicy::MAX_HTTP_TIMEOUT_SECONDS
            },
            allow_nil: true
  validate :delivery_overrides_require_pro_plan
  validate :retry_delays_must_be_positive_integers

  def pro?
    plan == PRO_PLAN
  end

  def member?(user)
    return false if user.nil?

    project_memberships.exists?(user_id: user.id)
  end

  def endpoint_count
    endpoints.not_archived.count
  end

  def plan_locked_endpoint_ids
    endpoints.not_archived.order(:created_at, :id).offset(Plans::Entitlements.endpoint_limit(self)).pluck(:id)
  end

  def deliveries_used_in_period(at = Time.current)
    ProjectUsagePeriod.used_deliveries(project: self, at: at)
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
