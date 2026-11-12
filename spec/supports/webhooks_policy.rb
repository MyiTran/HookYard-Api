RSpec.configure do |config|
  config.after do
    Webhooks::DeliveryPolicy.reset_jitter_source!
    Webhooks::CircuitPolicy.reset_disable_window!
    Webhooks::CircuitPolicy.reset_probe_interval!
  end
end
