module MessageAttemptSummary
  ATTEMPT_STATS_JOIN = <<~SQL.squish
    LEFT JOIN (
      SELECT message_id,
             COUNT(*) AS attempt_count,
             MAX(created_at) AS last_attempt_at,
             (ARRAY_AGG(response_status ORDER BY attempt_number DESC))[1] AS last_response_status,
             (ARRAY_AGG(duration_ms ORDER BY attempt_number DESC))[1] AS last_duration_ms,
             (ARRAY_AGG(error_type ORDER BY attempt_number DESC))[1] AS last_error_type
      FROM delivery_attempts
      GROUP BY message_id
    ) delivery_attempt_stats ON delivery_attempt_stats.message_id = messages.id
  SQL

  ATTEMPT_STATS_SELECT = <<~SQL.squish
    messages.*,
    COALESCE(delivery_attempt_stats.attempt_count, 0) AS attempt_count,
    delivery_attempt_stats.last_attempt_at,
    delivery_attempt_stats.last_response_status,
    delivery_attempt_stats.last_duration_ms,
    delivery_attempt_stats.last_error_type
  SQL

  private

  def with_attempt_summary(scope)
    scope.joins(ATTEMPT_STATS_JOIN).select(ATTEMPT_STATS_SELECT)
  end
end
