module SqlQueries
  IGNORED_NAMES = %w[SCHEMA].freeze
  IGNORED_STATEMENTS = ['BEGIN', 'COMMIT', 'ROLLBACK', 'SAVEPOINT', 'RELEASE SAVEPOINT'].freeze

  def sql_queries
    queries = []

    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      next if payload[:cached]
      next if IGNORED_NAMES.include?(payload[:name]) || IGNORED_STATEMENTS.include?(payload[:sql])

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }

    queries
  end
end

RSpec.configure do |config|
  config.include SqlQueries
end
