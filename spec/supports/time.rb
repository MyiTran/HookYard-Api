RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers

  config.after { travel_back }
end
