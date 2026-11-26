require 'rails_helper'
Rake::Task.define_task(:environment)
load Rails.root.join('lib/tasks/admin_demo.rake')

describe 'admin:demo:seed', type: :task do
  let(:task) { Rake::Task['admin:demo:seed'] }
  let(:admin_password) { 'demo-password-123' }
  let(:env_keys) do
    %w[HOOKYARD_DEMO_SEED DEMO_ADMIN_PASSWORD DEMO_DELIVERY_ATTEMPTS_TARGET ADMIN_DEMO_ATTEMPT_COUNT ADMIN_DEMO_DRY_RUN
       ADMIN_DEMO_CONFIRM_DATABASE ADMIN_DEMO_MAX_DB_MB]
  end
  let(:database_name) { ActiveRecord::Base.connection.select_value('SELECT current_database()') }

  around do |example|
    previous = env_keys.index_with { |key| ENV[key] }
    env_keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    task.reenable
  end

  def invoke_task
    task.reenable
    task.invoke
  rescue SystemExit
    nil
  end

  def seed_environment(attempts: '500')
    ENV['HOOKYARD_DEMO_SEED'] = '1'
    ENV['DEMO_ADMIN_PASSWORD'] = admin_password
    ENV['ADMIN_DEMO_ATTEMPT_COUNT'] = attempts
    ENV['ADMIN_DEMO_CONFIRM_DATABASE'] = database_name
  end

  def capture_stdout
    original_stdout = $stdout
    $stdout = StringIO.new

    invoke_task

    $stdout.string
  ensure
    $stdout = original_stdout
  end

  def demo_messages
    Message.where(event_id: Event.where("idempotency_key LIKE 'demo:event:%'").select(:id))
  end

  it 'requires the explicit seed guard' do
    expect { invoke_task }.to output(/HOOKYARD_DEMO_SEED=1/).to_stderr
    expect(User.where("email LIKE 'demo-account-%'")).to be_empty
  end

  it 'requires the demo admin password for a write run' do
    ENV['HOOKYARD_DEMO_SEED'] = '1'
    ENV['ADMIN_DEMO_CONFIRM_DATABASE'] = database_name

    expect { invoke_task }.to output(/DEMO_ADMIN_PASSWORD/).to_stderr
    expect(User.where("email LIKE 'demo-account-%'")).to be_empty
  end

  it 'refuses a target above the supported maximum' do
    seed_environment(attempts: (AdminDemo::Seeder::ATTEMPT_MAXIMUM + 1).to_s)

    expect { invoke_task }.to output(/between 1 and #{AdminDemo::Seeder::ATTEMPT_MAXIMUM}/).to_stderr
    expect(User.where("email LIKE 'demo-account-%'")).to be_empty
  end

  it 'refuses to write when the database confirmation does not match' do
    seed_environment
    ENV['ADMIN_DEMO_CONFIRM_DATABASE'] = 'some_other_database'

    expect { invoke_task }.to output(/ADMIN_DEMO_CONFIRM_DATABASE=#{database_name}/).to_stderr
    expect(User.where("email LIKE 'demo-account-%'")).to be_empty
  end

  it 'previews the target without writing in dry run mode' do
    ENV['HOOKYARD_DEMO_SEED'] = '1'
    ENV['ADMIN_DEMO_DRY_RUN'] = '1'
    ENV['ADMIN_DEMO_ATTEMPT_COUNT'] = '500'

    output = capture_stdout

    expect(output).to include('current demo attempts: 0')
    expect(output).to include('requested attempts:    500')
    expect(output).to include('additional attempts:')
    expect(output).to include('additional messages:')
    expect(output).to include('current database:')
    expect(output).to include('additional storage:')
    expect(output).to include('projected database:')
    expect(output).to include('dry run: nothing was written')
    expect(User.where("email LIKE 'demo-account-%'")).to be_empty
  end

  it 'uses the Render target env for a bounded dry run' do
    ENV['HOOKYARD_DEMO_SEED'] = '1'
    ENV['ADMIN_DEMO_DRY_RUN'] = '1'
    ENV['DEMO_DELIVERY_ATTEMPTS_TARGET'] = '100000'

    expect(capture_stdout).to include('requested attempts:    100000')
  end

  it 'prefers the Render target env over the legacy target env' do
    ENV['HOOKYARD_DEMO_SEED'] = '1'
    ENV['ADMIN_DEMO_DRY_RUN'] = '1'
    ENV['DEMO_DELIVERY_ATTEMPTS_TARGET'] = '100000'
    ENV['ADMIN_DEMO_ATTEMPT_COUNT'] = '500'

    expect(capture_stdout).to include('requested attempts:    100000')
  end

  it 'seeds the requested total and reports what it inserted' do
    seed_environment

    output = capture_stdout

    expect(output).to include('inserted accounts')
    expect(output).to include('inserted delivery_attempts')
    expect(output).not_to include(admin_password)
    expect(User.find_by(email: AdminDemo::Seeder::ADMIN_EMAIL)).to be_present
    expect(DeliveryAttempt.where(message_id: demo_messages.select(:id)).count).to be_between(400, 600)
  end

  it 'adds only the missing records on a rerun' do
    seed_environment
    invoke_task
    seeded = DeliveryAttempt.where(message_id: demo_messages.select(:id)).count

    output = capture_stdout

    expect(output).to include('additional attempts:   0')
    expect(output).to match(/inserted delivery_attempts\s+0/)
    expect(output).to match(/demo attempts now:\s+#{seeded}/)
    expect(DeliveryAttempt.where(message_id: demo_messages.select(:id)).count).to eq(seeded)
  end
end
