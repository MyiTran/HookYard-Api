require 'rails_helper'

# rubocop:disable RSpec/DescribeClass

describe 'config/schedule.yml' do
  let(:schedule) { YAML.load_file(Rails.root.join('config/schedule.yml')) }

  def cron_job(name)
    Sidekiq::Cron::Job.new(schedule.fetch(name).merge('name' => name))
  end

  it 'marks every scheduled ActiveJob entry as active_job' do
    schedule.each_value do |job_config|
      expect(job_config['active_job']).to be(true)
    end
  end

  it 'uses the ActiveJob wrapper instead of a raw class payload' do
    schedule.each_key do |name|
      job = cron_job(name)
      message = job.active_job_message

      expect(job.is_active_job?).to be(true)
      expect(message['class']).to eq('ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper')
      expect(message['wrapped']).to eq(job.klass)
      expect(message.dig('args', 0, 'job_class')).to eq(job.klass)
    end
  end
end

# rubocop:enable RSpec/DescribeClass
