module Admin
  class EndpointSerializer < ApplicationSerializer
    identifier :id

    fields :name, :active, :archived_at, :event_types, :circuit_state, :circuit_opened_at,
           :queued_message_count, :created_at, :updated_at

    field(:url) { |endpoint| Webhooks::EvidenceSanitizer.sanitize_url(endpoint.url) }

    field(:project) do |endpoint|
      { id: endpoint.project_id, name: endpoint.project.name }
    end

    view :detail do
      field(:paused) { |endpoint| endpoint.paused? }

      field(:account) do |endpoint|
        account = endpoint.project.billing_owner
        next nil if account.nil?

        { id: account.id, email: account.email, plan: account.plan }
      end

      field(:delivery_summary) do |_endpoint, options|
        options[:delivery_summary]
      end
    end
  end
end
