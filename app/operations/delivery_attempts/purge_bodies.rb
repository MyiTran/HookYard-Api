module DeliveryAttempts
  class PurgeBodies < ApplicationOperation
    BATCH_SIZE = 500

    def call(now: Time.current, batch_size: BATCH_SIZE)
      unless batch_size.is_a?(Integer) && batch_size.positive?
        raise ArgumentError, 'batch_size must be a positive integer'
      end

      User::PLANS.sum { |plan| purge_plan(plan, now, batch_size) }
    end

    private

    def purge_plan(plan, now, batch_size)
      cutoff = now - retention_days(plan).days
      last_id = nil
      purged = 0

      loop do
        ids = next_batch(plan, cutoff, last_id, batch_size)
        break if ids.empty?

        purged += purge(ids, now)
        last_id = ids.last
        break if ids.size < batch_size
      end

      purged
    end

    def next_batch(plan, cutoff, last_id, batch_size)
      scope = candidate_scope(plan, cutoff)
      scope = scope.where('delivery_attempts.id > ?', last_id) if last_id
      scope.order('delivery_attempts.id').limit(batch_size).pluck(:id)
    end

    def candidate_scope(plan, cutoff)
      DeliveryAttempt
        .joins(message: { event: { project: :billing_owner } })
        .where(users: { plan: plan })
        .where(bodies_purged_at: nil)
        .where('delivery_attempts.created_at < ?', cutoff)
        .where('delivery_attempts.response_status IS NOT NULL OR delivery_attempts.error_type IS NOT NULL')
    end

    def purge(ids, now)
      DeliveryAttempt
        .where(id: ids, bodies_purged_at: nil)
        .where('delivery_attempts.response_status IS NOT NULL OR delivery_attempts.error_type IS NOT NULL')
        .update_all(
          request_body: nil,
          response_body: nil,
          bodies_purged_at: now,
          updated_at: now
        )
    end

    def retention_days(plan)
      Plans::Entitlements.definition_for(plan).body_retention_days
    end
  end
end
