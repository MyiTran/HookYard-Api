require 'rails_helper'

RSpec.describe Pathname do
  let(:script) { Rails.root.join('bin/render-free-start') }
  let(:source) { File.read(script) }

  it 'is executable and starts Puma and Sidekiq with free-tier defaults' do
    expect(File).to exist(script)
    expect(File).to be_executable(script)
    expect(source).to include('WEB_CONCURRENCY:-1')
    expect(source).to include('RAILS_MAX_THREADS:-3')
    expect(source).to include('RAILS_MIN_THREADS:-3')
    expect(source).to include('SIDEKIQ_CONCURRENCY:-2')
    expect(source).to include('bundle exec puma')
    expect(source).to include('bundle exec sidekiq')
  end

  it 'forwards termination signals and stops the sibling process on failure' do
    expect(source).to include('trap shutdown TERM INT')
    expect(source).to include('wait -n')
    expect(source).to include('kill -TERM')
  end

  it 'runs migrations only when explicitly enabled before starting workers' do
    expect(source).to include('RUN_DB_MIGRATIONS')
    expect(source).to include('bundle exec rails db:migrate')
    expect(source).to include('if [[ "${RUN_DB_MIGRATIONS:-}" == "1" || "${RUN_DB_MIGRATIONS:-}" == "true" ]]')
    expect(source.index('bundle exec rails db:migrate')).to be < source.index('bundle exec puma')
  end

  it 'does not start workers when migration fails' do
    migration_block = source[/if \[\[.*?fi/m]

    expect(migration_block).to include('bundle exec rails db:migrate')
    expect(migration_block).to include('exit')
    expect(migration_block).not_to include('|| true')
  end
end
