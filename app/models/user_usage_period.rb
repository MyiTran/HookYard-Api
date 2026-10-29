# == Schema Information
#
# Table name: user_usage_periods
#
#  id               :uuid             not null, primary key
#  deliveries_count :integer          default(0), not null
#  period_starts_on :date             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  user_id          :uuid             not null
#
# Indexes
#
#  index_user_usage_periods_on_user_id_and_period_starts_on  (user_id,period_starts_on) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id) ON DELETE => cascade
#
class UserUsagePeriod < ApplicationRecord
  RESERVE_STATEMENT = <<~SQL.squish
    UPDATE user_usage_periods
    SET deliveries_count = deliveries_count + :quantity, updated_at = :at
    WHERE id = :id AND deliveries_count + :quantity <= :limit
    RETURNING deliveries_count
  SQL

  belongs_to :user

  validates :period_starts_on, presence: true
  validates :deliveries_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  class << self
    def period_start_for(time)
      time.utc.beginning_of_month.to_date
    end

    def period_starts_at(time = Time.current)
      period_start_for(time).beginning_of_day.utc
    end

    def period_ends_at(time = Time.current)
      period_start_for(time).next_month.beginning_of_day.utc
    end

    def used_deliveries(user:, at: Time.current)
      where(user_id: user.id, period_starts_on: period_start_for(at)).pick(:deliveries_count) || 0
    end

    def reserve_deliveries(user:, quantity:, limit:, at: Time.current)
      return true unless quantity.positive?

      period = ensure_period!(user: user, period_starts_on: period_start_for(at))

      !reserved_total(period, quantity: quantity, limit: limit, at: at).nil?
    end

    def ensure_period!(user:, period_starts_on:)
      insert_all(
        [{
          user_id: user.id,
          period_starts_on: period_starts_on,
          created_at: Time.current,
          updated_at: Time.current
        }],
        unique_by: %i[user_id period_starts_on]
      )

      find_by!(user_id: user.id, period_starts_on: period_starts_on)
    end

    private

    def reserved_total(period, quantity:, limit:, at:)
      connection.select_value(
        sanitize_sql_array([RESERVE_STATEMENT, { id: period.id, quantity: quantity, limit: limit, at: at }])
      )
    end
  end
end
