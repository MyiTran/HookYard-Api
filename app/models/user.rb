# == Schema Information
#
# Table name: users
#
#  id                     :uuid             not null, primary key
#  confirmation_sent_at   :datetime
#  confirmation_token     :string
#  confirmed_at           :datetime
#  current_sign_in_at     :datetime
#  current_sign_in_ip     :string
#  email                  :string           default(""), not null
#  encrypted_password     :string           default(""), not null
#  first_name             :string           default(""), not null
#  last_name              :string           default(""), not null
#  last_sign_in_at        :datetime
#  last_sign_in_ip        :string
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  sign_in_count          :integer          default(0), not null
#  unconfirmed_email      :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  plan                   :string           default("free"), not null
#
# Indexes
#
#  index_users_on_confirmation_token    (confirmation_token) UNIQUE
#  index_users_on_email                 (email) UNIQUE
#  index_users_on_reset_password_token  (reset_password_token) UNIQUE
#
class User < ApplicationRecord
  include Devise::JWT::RevocationStrategies::Allowlist

  rolify

  FREE_PLAN = 'free'
  PRO_PLAN = 'pro'
  PLANS = [FREE_PLAN, PRO_PLAN].freeze

  devise :database_authenticatable, :registerable, :confirmable, :recoverable,
         :validatable, :trackable, :jwt_authenticatable, jwt_revocation_strategy: self

  has_one_attached :avatar
  has_many :project_memberships, dependent: :destroy
  has_many :projects, through: :project_memberships
  has_many :owned_projects, class_name: 'Project', foreign_key: :billing_owner_id,
                            inverse_of: :billing_owner, dependent: :restrict_with_error
  has_many :usage_periods, class_name: 'UserUsagePeriod', dependent: :destroy
  has_many :notifications, dependent: :destroy

  validates :first_name, presence: true
  validates :last_name, presence: true
  validates :plan, inclusion: { in: PLANS }

  def name
    "#{first_name} #{last_name}".strip
  end

  def admin?
    has_role?(:admin)
  end

  def support?
    has_role?(:support)
  end

  def pro?
    plan == PRO_PLAN
  end

  def owned_project_count
    owned_projects.count
  end

  def deliveries_used_in_period(at = Time.current)
    UserUsagePeriod.used_deliveries(user: self, at: at)
  end
end
