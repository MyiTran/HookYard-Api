require 'rails_helper'

RSpec.describe Pathname do
  let(:script) { Rails.root.join('bin/render-demo-seed') }
  let(:source) { File.read(script) }

  it 'is an executable one-time runner for the admin demo task' do
    expect(File).to be_executable(script)
    expect(source).to start_with("#!/usr/bin/env bash\n")
    expect(source).to include('exec bundle exec rake admin:demo:seed')
    expect(source).not_to include('bundle exec puma')
    expect(source).not_to include('bundle exec sidekiq')
    expect(source).not_to include('&&')
  end

  it 'requires the protected write-run environment' do
    %w[HOOKYARD_DEMO_SEED DEMO_ADMIN_PASSWORD ADMIN_DEMO_CONFIRM_DATABASE
       DEMO_DELIVERY_ATTEMPTS_TARGET].each do |key|
      expect(source).to include(key)
    end
    expect(source).to include('ADMIN_DEMO_DRY_RUN')
    expect(source).to include('exit 64')
  end

  it 'does not print secret values' do
    expect(source).not_to include('DATABASE_URL')
    expect(source).not_to include('DEMO_ADMIN_PASSWORD=')
  end
end
