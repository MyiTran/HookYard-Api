module Plans
  class Entitlements
    PLANNED_CAPABILITIES = %i[
      custom_delivery_schedule
      custom_delivery_timeout
      message_payload_retention
      delivery_log
      replay
      circuit_breaker
      realtime_notifications
      ai_diagnosis
      admin_console
    ].freeze

    Definition = Struct.new(:project_limit, :endpoint_limit, :monthly_delivery_limit, :body_retention_days, keyword_init: true)

    DEFINITIONS = {
      User::FREE_PLAN => Definition.new(
        project_limit: 2, endpoint_limit: 3, monthly_delivery_limit: 10_000, body_retention_days: 3
      ),
      User::PRO_PLAN => Definition.new(
        project_limit: 10, endpoint_limit: 50, monthly_delivery_limit: 500_000, body_retention_days: 30
      )
    }.freeze

    class << self
      def definition_for(plan)
        DEFINITIONS.fetch(plan.to_s)
      end

      def project_limit(account)
        definition_for(account.plan).project_limit
      end

      def endpoint_limit(account)
        definition_for(account.plan).endpoint_limit
      end

      def monthly_delivery_limit(account)
        definition_for(account.plan).monthly_delivery_limit
      end

      def body_retention_days(account)
        definition_for(account.plan).body_retention_days
      end
    end
  end
end
