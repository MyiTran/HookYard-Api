RSpec.configure do |config|
  circuit_environment_keys = %w[
    WEBHOOK_CIRCUIT_DISABLE_WINDOW_SECONDS
    WEBHOOK_CIRCUIT_PROBE_INTERVAL_SECONDS
  ].freeze

  config.around do |example|
    previous_values = circuit_environment_keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    circuit_environment_keys.each { |key| ENV.delete(key) }

    example.run
  ensure
    previous_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
