class EndpointSerializer < ApplicationSerializer
  identifier :id

  fields :name, :url, :description, :active, :event_types, :archived_at, :created_at, :updated_at

  field :project do |endpoint|
    { id: endpoint.project_id, name: endpoint.project.name, plan: endpoint.project.plan }
  end

  field :has_signing_secret do |endpoint|
    endpoint.has_signing_secret?
  end

  field :signing_secret_version do |endpoint|
    endpoint.signing_secret_version
  end

  field :signing_secret_last_rotated_at do |endpoint|
    endpoint.current_signing_secret&.created_at
  end

  field :circuit do |endpoint, options|
    counts = delivery_counts_for(endpoint, options)
    last_probe = endpoint.last_circuit_probe

    {
      state: endpoint.circuit_state,
      opened_at: endpoint.circuit_opened_at,
      failure_count: endpoint.circuit_failure_count,
      failure_threshold: Webhooks::CircuitPolicy::FAILURE_THRESHOLD,
      disable_window_ends_at: endpoint.circuit_disable_at,
      next_probe_at: endpoint.circuit_next_probe_at,
      probe_in_flight: endpoint.probe_in_flight?,
      held_count: counts.fetch(:held_count),
      last_probe: last_probe && CircuitProbeSerializer.render_as_hash(last_probe)
    }
  end

  field :plan_locked do |endpoint, options|
    locks = options[:plan_locks]

    locks ? locks.locked?(endpoint) : endpoint.project.plan_locked_endpoint_ids.include?(endpoint.id)
  end

  field :queue do |endpoint, options|
    counts = delivery_counts_for(endpoint, options)
    backlog_total = counts.fetch(:backlog_total)

    {
      state: endpoint.queue_state(backlog_total),
      backlog_total: backlog_total,
      dispatchable_count: counts.fetch(:dispatchable_count),
      capacity: Webhooks::CircuitPolicy::QUEUE_CAPACITY
    }
  end

  view :with_signing_secret do
    field :signing_secret do |_endpoint, options|
      options[:signing_secret]
    end
  end

  def self.delivery_counts_for(endpoint, options)
    options[:delivery_counts]&.for(endpoint) || endpoint.delivery_counts
  end
end
