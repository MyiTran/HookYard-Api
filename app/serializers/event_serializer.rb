class EventSerializer < ApplicationSerializer
  identifier :id

  fields :event_type, :created_at

  field :status do |_event, options|
    options.fetch(:created, true) ? 'accepted' : 'duplicate'
  end

  field :messages_count do |_event, options|
    options[:messages_count] || 0
  end
end
