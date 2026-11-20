require 'rails_helper'
Rails.application.load_tasks

describe 'data_backfills:enqueue_plan_backfills', type: :task do
  before { Rake::Task['data_backfills:enqueue_plan_backfills'].reenable }

  it 'enqueues every manually triggered backfill job once' do
    expect { Rake::Task['data_backfills:enqueue_plan_backfills'].invoke }
      .to have_enqueued_job(Billing::BackfillProjectBillingOwnersJob).once
      .and have_enqueued_job(Ingest::BackfillRejectionIdempotencyKeyDigestsJob).once
      .and have_enqueued_job(DeliveryMetrics::BackfillJob).once
  end
end
