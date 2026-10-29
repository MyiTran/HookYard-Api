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

    Definition = Struct.new(:endpoint_limit, :monthly_delivery_limit, keyword_init: true)

    DEFINITIONS = {
      Project::FREE_PLAN => Definition.new(endpoint_limit: 3, monthly_delivery_limit: 10_000),
      Project::PRO_PLAN => Definition.new(endpoint_limit: 50, monthly_delivery_limit: 500_000)
    }.freeze

    class << self
      def definition_for(plan)
        DEFINITIONS.fetch(plan.to_s)
      end

      def endpoint_limit(project)
        definition_for(project.plan).endpoint_limit
      end

      def monthly_delivery_limit(project)
        definition_for(project.plan).monthly_delivery_limit
      end
    end
  end
end
