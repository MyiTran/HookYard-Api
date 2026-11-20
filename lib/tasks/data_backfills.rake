namespace :data_backfills do
  desc 'Enqueue the manually triggered data backfill jobs'
  task enqueue_plan_backfills: :environment do
    Billing::BackfillProjectBillingOwnersJob.perform_later
    Ingest::BackfillRejectionIdempotencyKeyDigestsJob.perform_later
    DeliveryMetrics::BackfillJob.perform_later

    puts 'Enqueued Billing::BackfillProjectBillingOwnersJob, Ingest::BackfillRejectionIdempotencyKeyDigestsJob and DeliveryMetrics::BackfillJob'
  end
end
