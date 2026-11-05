class IngestRejectionSerializer < ApplicationSerializer
  identifier :id

  fields :reason, :event_type, :created_at

  field :project do |rejection|
    { id: rejection.project_id, name: rejection.project.name }
  end

  field :endpoint do |rejection|
    endpoint = rejection.endpoint
    endpoint && { id: endpoint.id, name: endpoint.name }
  end

  field :payload_keys do |rejection|
    Array(rejection.payload['payload_keys'])
  end

  field :payload_bytes do |rejection|
    rejection.payload['payload_bytes']
  end
end
