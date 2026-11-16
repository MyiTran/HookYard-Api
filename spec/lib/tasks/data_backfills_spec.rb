require 'rails_helper'
Rails.application.load_tasks

describe 'data_backfills:enqueue_plan_backfills', type: :task do
  before { Rake::Task['data_backfills:enqueue_plan_backfills'].reenable }

  it 'enqueues both plan backfill jobs once' do
    expect { Rake::Task['data_backfills:enqueue_plan_backfills'].invoke }
      .to have_enqueued_job(Billing::BackfillProjectBillingOwnersJob).once
      .and have_enqueued_job(Ingest::BackfillRejectionIdempotencyKeyDigestsJob).once
  end
end
