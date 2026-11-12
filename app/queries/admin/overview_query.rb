module Admin
  class OverviewQuery < ApplicationQuery
    DELIVERY_METRIC_WINDOW_DAYS = 30

    def call
      {
        generated_at: Time.current,
        accounts: accounts_summary,
        projects: projects_summary,
        endpoints: endpoints_summary,
        deliveries: deliveries_summary
      }
    end

    private

    def accounts_summary
      {
        total: User.count,
        admins: User.with_role(:admin).count,
        support: User.with_role(:support).count,
        unconfirmed: User.where(confirmed_at: nil).count
      }
    end

    def projects_summary
      { total: Project.count }
    end

    def endpoints_summary
      circuit_states = Endpoint.group(:circuit_state).count

      {
        active: Endpoint.not_archived.active.count,
        circuit_open: circuit_states.fetch(Endpoint.circuit_states[:circuit_open], 0),
        disabled: circuit_states.fetch(Endpoint.circuit_states[:disabled], 0),
        queued_messages: Endpoint.sum(:queued_message_count)
      }
    end

    def deliveries_summary
      totals = DeliveryMetric
               .where('day >= ?', DELIVERY_METRIC_WINDOW_DAYS.days.ago.to_date)
               .pick(
                 Arel.sql('COALESCE(SUM(attempts_count), 0)'),
                 Arel.sql('COALESCE(SUM(successes_count), 0)'),
                 Arel.sql('COALESCE(SUM(failures_count), 0)')
               )

      total_attempts = totals[0].to_i
      succeeded_attempts = totals[1].to_i
      failed_attempts = totals[2].to_i

      {
        window_days: DELIVERY_METRIC_WINDOW_DAYS,
        total_attempts: total_attempts,
        succeeded_attempts: succeeded_attempts,
        failed_attempts: failed_attempts,
        success_rate: total_attempts.positive? ? (succeeded_attempts.to_f / total_attempts * 100).round(2) : 0.0,
        in_flight: Message.delivering.count + Message.pending.not_held.count,
        held: Message.held.count,
        retries_due: Message.due_for_delivery.count
      }
    end
  end
end
