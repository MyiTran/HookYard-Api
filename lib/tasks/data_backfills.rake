namespace :data_backfills do
  desc 'Enqueue the plan data backfill jobs'
  task enqueue_plan_backfills: :environment do
    Billing::BackfillProjectBillingOwnersJob.perform_later
    Ingest::BackfillRejectionIdempotencyKeyDigestsJob.perform_later

    puts 'Enqueued Billing::BackfillProjectBillingOwnersJob and Ingest::BackfillRejectionIdempotencyKeyDigestsJob'
  end
end
