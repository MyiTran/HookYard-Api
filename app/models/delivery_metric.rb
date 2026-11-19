# == Schema Information
#
# Table name: delivery_metrics
#
#  id              :uuid             not null, primary key
#  attempts_count  :integer          default(0), not null
#  day             :date             not null
#  failures_count  :integer          default(0), not null
#  successes_count :integer          default(0), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  project_id      :uuid             not null
#
# Indexes
#
#  index_delivery_metrics_on_project_id          (project_id)
#  index_delivery_metrics_on_project_id_and_day  (project_id,day) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (project_id => projects.id) ON DELETE => cascade
#
class DeliveryMetric < ApplicationRecord
  UPSERT_COLUMNS = <<~SQL.squish
    attempts_count = delivery_metrics.attempts_count + EXCLUDED.attempts_count,
    successes_count = delivery_metrics.successes_count + EXCLUDED.successes_count,
    failures_count = delivery_metrics.failures_count + EXCLUDED.failures_count,
    updated_at = EXCLUDED.updated_at
  SQL

  DEFAULT_BACKFILL_BATCH_SIZE = 1_000

  BACKFILL_BATCH_SQL = <<~SQL
    WITH claimed AS (
      SELECT id
      FROM delivery_attempts
      WHERE metrics_recorded_at IS NULL
        AND (
          response_status IS NOT NULL
          OR (error_type IS NOT NULL AND BTRIM(error_type) <> '')
        )
      ORDER BY id
      LIMIT ?
      FOR UPDATE SKIP LOCKED
    ), claimed_attempts AS (
      UPDATE delivery_attempts
      SET metrics_recorded_at = NOW()
      WHERE id IN (SELECT id FROM claimed)
        AND metrics_recorded_at IS NULL
      RETURNING message_id, response_status, error_type, created_at
    ), aggregated_attempts AS (
      SELECT endpoints.project_id,
             (claimed_attempts.created_at AT TIME ZONE 'UTC')::date AS day,
             COUNT(*) AS attempts_count,
             COUNT(*) FILTER (WHERE claimed_attempts.response_status BETWEEN 200 AND 299) AS successes_count,
             COUNT(*) FILTER (
               WHERE claimed_attempts.response_status IS NULL
                 OR NOT (claimed_attempts.response_status BETWEEN 200 AND 299)
             ) AS failures_count
      FROM claimed_attempts
      JOIN messages ON messages.id = claimed_attempts.message_id
      JOIN endpoints ON endpoints.id = messages.endpoint_id
      GROUP BY endpoints.project_id, (claimed_attempts.created_at AT TIME ZONE 'UTC')::date
    )
    INSERT INTO delivery_metrics (project_id, day, attempts_count, successes_count, failures_count, created_at, updated_at)
    SELECT project_id, day, attempts_count, successes_count, failures_count, NOW(), NOW()
    FROM aggregated_attempts
    ON CONFLICT (project_id, day)
    DO UPDATE SET #{UPSERT_COLUMNS}
  SQL

  belongs_to :project

  validates :day, presence: true
  validates :attempts_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :successes_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failures_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  class << self
    def record_attempt!(attempt)
      return if attempt.message.nil?
      return unless attempt.completed?

      transaction(requires_new: true) do
        claimed = DeliveryAttempt.where(id: attempt.id, metrics_recorded_at: nil)
                                 .update_all(metrics_recorded_at: Time.current)
        next if claimed.zero?

        upsert_all(
          [{
            project_id: attempt.message.endpoint.project_id,
            day: attempt.created_at.utc.to_date,
            attempts_count: 1,
            successes_count: attempt.succeeded? ? 1 : 0,
            failures_count: attempt.succeeded? ? 0 : 1,
            created_at: Time.current,
            updated_at: Time.current
          }],
          unique_by: %i[project_id day],
          on_duplicate: Arel.sql(UPSERT_COLUMNS)
        )
      end
    rescue StandardError => e
      Rails.logger.warn("DeliveryMetric.record_attempt! skipped: #{e.class}: #{e.message}")
      nil
    end

    def backfill_missing!(batch_size: DEFAULT_BACKFILL_BATCH_SIZE)
      DeliveryMetrics::Backfill.call(batch_size: batch_size)
    end

    def backfill_batch(batch_size)
      connection.execute(
        sanitize_sql_array([BACKFILL_BATCH_SQL, batch_size.to_i])
      ).cmd_tuples
    end
  end
end
