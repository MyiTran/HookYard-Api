namespace :admin do
  namespace :demo do
    desc 'Seed admin demo data up to ADMIN_DEMO_ATTEMPT_COUNT (ADMIN_DEMO_DRY_RUN=1 previews, ADMIN_DEMO_CONFIRM_DATABASE names the target)'
    task seed: :environment do
      abort 'Set HOOKYARD_DEMO_SEED=1 to run the admin demo seed' unless ENV['HOOKYARD_DEMO_SEED'] == '1'

      dry_run = ENV['ADMIN_DEMO_DRY_RUN'] == '1'
      admin_password = ENV.fetch('DEMO_ADMIN_PASSWORD', '').strip
      abort 'DEMO_ADMIN_PASSWORD is required for the admin demo seed' if admin_password.blank? && !dry_run

      report = AdminDemo::Seeder.call(
        attempt_count: ENV.fetch('ADMIN_DEMO_ATTEMPT_COUNT', AdminDemo::Seeder::ATTEMPT_DEFAULT.to_s),
        admin_password: admin_password,
        dry_run: dry_run,
        database_confirmation: ENV['ADMIN_DEMO_CONFIRM_DATABASE'],
        max_database_size_mb: ENV['ADMIN_DEMO_MAX_DB_MB']
      )

      size = ->(bytes) { ActiveSupport::NumberHelper.number_to_human_size(bytes) }
      database = report[:database]

      puts "Admin demo seed#{' dry run' if report[:dry_run]} on #{database[:name]} (#{database[:environment]})"
      puts format('  current demo attempts: %d', report[:existing][:delivery_attempts])
      puts format('  requested attempts:    %d', report[:requested_attempt_count])
      puts format('  additional attempts:   %d', report[:pending][:delivery_attempts])
      puts format('  additional messages:   %d', report[:pending][:messages])
      puts format('  additional events:     %d', report[:pending][:events])
      puts format('  current database:      %s', size.call(database[:current_bytes]))
      puts format('  additional storage:    %s (estimate)', size.call(database[:growth_bytes]))
      puts format('  projected database:    %s of %s',
                  size.call(database[:projected_bytes]), size.call(database[:limit_bytes]))
      puts format('  batches to process:    %d', (report[:pending][:messages].to_f / AdminDemo::Seeder::BATCH_SIZE).ceil)

      if report[:dry_run]
        puts '  dry run: nothing was written'
      else
        report[:inserted].each { |key, value| puts format('  inserted %-20s %d', key, value) }
        puts format('  demo attempts now:     %d', report[:final][:delivery_attempts])
      end

      if report[:requested_attempt_count] < (report[:final] || report[:existing])[:delivery_attempts]
        puts '  note: the requested target is below the existing demo attempts; nothing is deleted'
      end

      puts "  admin login:           #{AdminDemo::Seeder::ADMIN_EMAIL}"
    rescue AdminDemo::Seeder::Error, ArgumentError => e
      abort e.message
    end
  end
end
