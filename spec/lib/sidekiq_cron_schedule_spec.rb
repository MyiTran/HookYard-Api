require 'rails_helper'

describe 'Sidekiq cron schedule', type: :model do
  schedule = YAML.load_file(Rails.root.join('config/schedule.yml'))

  def active_job_entry?(entry)
    klass = entry['class'].safe_constantize
    klass.present? && klass < ActiveJob::Base
  end

  def build_cron_job(name, entry)
    Sidekiq::Cron::Job.new(
      name: name,
      cron: entry['cron'],
      class: entry['class'],
      queue: entry['queue'],
      active_job: entry['active_job']
    )
  end

  describe 'active job entries' do
    it 'flags every ActiveJob-backed entry so sidekiq-cron enqueues Rails jobs' do
      entries = schedule.select { |_name, entry| active_job_entry?(entry) }

      expect(entries.keys).to include('webhook_delivery_retry_sweep', 'recover_pending_webhook_deliveries')

      aggregate_failures do
        entries.each do |name, entry|
          expect(entry['active_job']).to be(true), "#{name} must declare active_job: true"
        end
      end
    end

    it 'leaves native Sidekiq workers unmarked' do
      native_entries = schedule.reject { |_name, entry| active_job_entry?(entry) }

      aggregate_failures do
        native_entries.each do |name, entry|
          expect(entry).not_to have_key('active_job'), "#{name} is a native Sidekiq worker"
        end
      end
    end
  end

  describe 'enqueued payload' do
    it 'wraps the scheduled ActiveJob classes instead of pushing them as native workers' do
      aggregate_failures do
        schedule.each do |name, entry|
          cron_job = build_cron_job(name, entry)
          payload = cron_job.send(:active_job_message)

          expect(cron_job.send(:is_active_job?)).to be(true), "#{name} must be enqueued as an ActiveJob"
          expect(payload['class']).not_to eq(entry['class'])
          expect(payload['class']).to end_with('Wrapper')
          expect(payload['class'].safe_constantize).to respond_to(:perform_async)
          expect(payload['wrapped']).to eq(entry['class'])
        end
      end
    end
  end

  describe 'schedule contract' do
    it 'keeps the documented cron expressions, job classes and queues' do
      expect(schedule).to eq(
        'purge_anattached_blobs_job' => {
          'cron' => '0 0 * * *',
          'class' => 'ActiveStorage::PurgeUnattachedBlobsJob',
          'queue' => 'default',
          'active_job' => true
        },
        'purge_expired_jwts_job' => {
          'cron' => '0 0 * * *',
          'class' => 'DeviseJwt::PurgeExpiredJwtsJob',
          'queue' => 'default',
          'active_job' => true
        },
        'webhook_delivery_retry_sweep' => {
          'cron' => '* * * * *',
          'class' => 'Messages::RetrySweepJob',
          'queue' => 'default',
          'active_job' => true
        },
        'recover_pending_webhook_deliveries' => {
          'cron' => '* * * * *',
          'class' => 'Messages::PendingDeliveryRecoveryJob',
          'queue' => 'default',
          'active_job' => true
        }
      )
    end
  end
end
