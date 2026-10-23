RSpec.configure do |config|
  config.before do
    adapter = ActiveJob::Base.queue_adapter
    adapter.enqueued_jobs.clear if adapter.respond_to?(:enqueued_jobs)
  end
end
