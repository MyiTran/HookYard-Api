# == Schema Information
#
# Table name: project_usage_periods
#
#  id               :uuid             not null, primary key
#  deliveries_count :integer          default(0), not null
#  period_starts_on :date             not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  project_id       :uuid             not null
#
# Indexes
#
#  index_project_usage_periods_on_project_id                       (project_id)
#  index_project_usage_periods_on_project_id_and_period_starts_on  (project_id,period_starts_on) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class ProjectUsagePeriod < ApplicationRecord
  RESERVE_STATEMENT = <<~SQL.squish
    UPDATE project_usage_periods
    SET deliveries_count = deliveries_count + :quantity, updated_at = :at
    WHERE id = :id AND deliveries_count + :quantity <= :limit
    RETURNING deliveries_count
  SQL

  belongs_to :project

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

    def used_deliveries(project:, at: Time.current)
      where(project_id: project.id, period_starts_on: period_start_for(at)).pick(:deliveries_count) || 0
    end

    def reserve_deliveries(project:, quantity:, limit:, at: Time.current)
      return true unless quantity.positive?

      period = ensure_period!(project: project, period_starts_on: period_start_for(at))

      !reserved_total(period, quantity: quantity, limit: limit, at: at).nil?
    end

    def ensure_period!(project:, period_starts_on:)
      insert_all(
        [{
          project_id: project.id,
          period_starts_on: period_starts_on,
          created_at: Time.current,
          updated_at: Time.current
        }],
        unique_by: %i[project_id period_starts_on]
      )

      find_by!(project_id: project.id, period_starts_on: period_starts_on)
    end

    private

    def reserved_total(period, quantity:, limit:, at:)
      connection.select_value(
        sanitize_sql_array([RESERVE_STATEMENT, { id: period.id, quantity: quantity, limit: limit, at: at }])
      )
    end
  end
end
