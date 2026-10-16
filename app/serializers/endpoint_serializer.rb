class EndpointSerializer < ApplicationSerializer
  identifier :id

  fields :name, :url, :description, :active, :event_types, :archived_at, :created_at, :updated_at

  field :project do |endpoint|
    { id: endpoint.project_id, name: endpoint.project.name }
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

  view :with_signing_secret do
    field :signing_secret do |_endpoint, options|
      options[:signing_secret]
    end
  end
end
