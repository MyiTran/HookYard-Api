module Admin
  class ProjectSerializer < ApplicationSerializer
    identifier :id

    fields :name, :created_at, :updated_at

    field(:plan) { |project| project.billing_owner&.plan }

    field(:account) do |project|
      account = project.billing_owner
      next nil if account.nil?

      { id: account.id, email: account.email, plan: account.plan }
    end

    view :detail do
      field(:member_count) { |project| project.project_memberships.size }

      field(:endpoint_summary) do |project|
        endpoints = project.endpoints.to_a

        {

          total: endpoints.size,
          active: endpoints.count(&:active?),
          paused: endpoints.count(&:paused?),
          archived: endpoints.count(&:archived?),
          enabled: endpoints.count(&:enabled?),
          circuit_open: endpoints.count(&:circuit_open?),
          disabled: endpoints.count(&:disabled?),
          queued_messages: endpoints.sum(&:queued_message_count)
        }
      end
    end
  end
end
