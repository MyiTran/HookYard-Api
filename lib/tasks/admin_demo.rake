namespace :admin do
  namespace :demo do
    desc 'Seed HookYard admin demo data (requires HOOKYARD_DEMO_SEED=1 and DEMO_ADMIN_PASSWORD)'
    task seed: :environment do
      abort 'Set HOOKYARD_DEMO_SEED=1 to run the admin demo seed' unless ENV['HOOKYARD_DEMO_SEED'] == '1'

      admin_password = ENV.fetch('DEMO_ADMIN_PASSWORD', '').strip
      abort 'DEMO_ADMIN_PASSWORD is required for the admin demo seed' if admin_password.blank?

      attempt_count = Integer(ENV.fetch('ADMIN_DEMO_ATTEMPT_COUNT', AdminDemo::Seeder::ATTEMPT_DEFAULT.to_s))
      abort 'ADMIN_DEMO_ATTEMPT_COUNT must be a positive integer' unless attempt_count.positive?

      counts = AdminDemo::Seeder.call(attempt_count: attempt_count, admin_password: admin_password)

      puts "Admin demo seed complete (#{attempt_count} target attempts):"
      counts.each { |key, value| puts format('  %-18s %d', key, value) }
      puts "  admin login:      #{AdminDemo::Seeder::ADMIN_EMAIL}"
    rescue ArgumentError => e
      abort e.message
    end
  end
end
