namespace :admin do
  desc 'Create the first administrator from BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD'
  task bootstrap: :environment do
    Users::BootstrapAdmin.call(
      email: ENV['BOOTSTRAP_ADMIN_EMAIL'],
      password: ENV['BOOTSTRAP_ADMIN_PASSWORD'],
      override: ENV['BOOTSTRAP_ADMIN_OVERRIDE'] == '1'
    )
  rescue Users::BootstrapAdmin::MissingCredentialsError,
         Users::BootstrapAdmin::ExistingUserConflictError,
         Users::BootstrapAdmin::ExistingAdministratorConflictError => error

    abort error.message
  end
end
