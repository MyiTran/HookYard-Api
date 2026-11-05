class ReplayRunSerializer < ApplicationSerializer
  identifier :id

  fields :mode, :project_id, :requested_count, :filters, :materialized_at, :created_at, :updated_at

  field :status do |run|
    run.progress[:status]
  end

  field :summary do |run|
    run.progress[:summary]
  end

  field :actor do |run|
    { id: run.actor_id, name: run.actor.name }
  end

  view :with_items do
    field :items do |run|
      run.replay_items.includes(:delivery_attempt).order(:created_at, :id).map do |item|
        ReplayItemSerializer.render_as_hash(item)
      end
    end
  end
end
