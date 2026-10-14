module ActionCableHelpers
  def cable_messages(stream)
    ActionCable.server.pubsub.broadcasts(stream).map { |message| JSON.parse(message) }
  end

  def clear_cable_messages(stream)
    ActionCable.server.pubsub.clear_messages(stream)
  end
end

RSpec.configure do |config|
  config.include ActionCableHelpers
end
