require 'rails_helper'
Rake.application.rake_require('tasks/admin', [Rails.root.join('lib').to_s]) unless Rake::Task.task_defined?('admin:bootstrap')

describe 'admin:bootstrap', type: :task do
  let(:task) { Rake::Task['admin:bootstrap'] }

  around do |example|
    original_email = ENV['BOOTSTRAP_ADMIN_EMAIL']
    original_password = ENV['BOOTSTRAP_ADMIN_PASSWORD']
    original_override = ENV['BOOTSTRAP_ADMIN_OVERRIDE']

    example.run
  ensure
    ENV['BOOTSTRAP_ADMIN_EMAIL'] = original_email
    ENV['BOOTSTRAP_ADMIN_PASSWORD'] = original_password
    ENV['BOOTSTRAP_ADMIN_OVERRIDE'] = original_override
    task.reenable
  end

  it 'reads the bootstrap credentials from the environment' do
    ENV['BOOTSTRAP_ADMIN_EMAIL'] = 'admin@example.test'
    ENV['BOOTSTRAP_ADMIN_PASSWORD'] = 'a-strong-password'

    expect { task.invoke }.to change(User, :count).by(1)
    expect(User.find_by!(email: 'admin@example.test')).to be_admin
  end
end
