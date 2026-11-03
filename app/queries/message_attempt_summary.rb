module MessageAttemptSummary
  ATTEMPT_STATS_JOIN = <<~SQL.squish
    LEFT JOIN LATERAL (
      SELECT MAX(delivery_attempts.created_at) AS last_attempt_at,
             (ARRAY_AGG(delivery_attempts.response_status ORDER BY delivery_attempts.attempt_number DESC))[1] AS last_response_status,
             (ARRAY_AGG(delivery_attempts.duration_ms ORDER BY delivery_attempts.attempt_number DESC))[1] AS last_duration_ms,
             (ARRAY_AGG(delivery_attempts.error_type ORDER BY delivery_attempts.attempt_number DESC))[1] AS last_error_type
      FROM delivery_attempts
      WHERE delivery_attempts.message_id = messages.id
    ) delivery_attempt_stats ON TRUE
  SQL

  ATTEMPT_STATS_SELECT = <<~SQL.squish
    messages.*,
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
