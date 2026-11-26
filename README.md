# Golden Owl Solutions Rails API Boilerplate

A boilerplate for quickly setting up a Rails API:

- Ruby (3.4.1)
- Rails (8.0.2)
- PostgreSQL
- Sidekiq, Redis
- Devise, Devise JWT
- Swagger
- Sentry
- RSpec

## Getting Started

Follow these steps to install and start the application:

- Install ruby `3.4.1`
```bash
rbenv install 3.4.1
rbenv local 3.4.1
ruby -v
```
- Install gems:
```bash
gem install bundler
bundle install
```
- Add `config/database.yml` file (reference: `config/database.yml.sample`)
- Add `.env` file (reference: `.env.sample`)
- Generate Active Record Encryption keys and add them to `.env`:
```bash
bin/rails db:encryption:init
```
```bash
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=...
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=...
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=...
```
Nonblank `ACTIVE_RECORD_ENCRYPTION_*` values override the matching keys in Rails credentials; the `test` environment uses isolated keys from `config/environments/test.rb`. The `production` environment refuses to boot when a key is missing.
- Generate new rails master key
```bash
rm -f config/credentials.yml.enc && rm -f config/master.key && EDITOR=vim bin/rails credentials:edit
```
- Database setup:
```bash
bin/rails db:setup
```
- Start server:
```bash
bin/rails s
bundle exec sidekiq
```

**Existing encrypted data**

Encrypted columns (for example `endpoint_signing_secrets.secret`) can only be decrypted with the keys that wrote them. When moving from a previous key configuration:

1. Read the currently active encryption keys from the running application and store them in the environment before deploying the new configuration.
2. Re-encrypt existing records with the new independent keys in a controlled task, then rotate the keys.

Never drop or regenerate Endpoint signing secrets just to make decryption succeed.

**Local webhook receivers**

Endpoint URLs must be public HTTP(S) destinations; loopback, private networks, and internal hostnames are rejected. Expose a local receiver through a public tunnel (for example `ngrok http 3000`) instead of bypassing validation.

**Specs**

```bash
bundle exec rspec
```

Check the coverage at `coverage/index.html`

**API Doc**

```bash
bin/rake rswag
```

Check the generated document at `http://localhost:3000/docs`

**Security Vulnerability Scanner**

```bash
bundle exec brakeman
```

**Linter With Rubocop**

```bash
bundle exec rubocop
```

## Admin demo data

`admin:demo:seed` fills an environment with namespaced demo accounts, projects, endpoints, deliveries and
metric rollups. It never runs on its own, never enqueues Sidekiq jobs and never sends webhooks.

```bash
HOOKYARD_DEMO_SEED=1 \
DEMO_ADMIN_PASSWORD=<password> \
ADMIN_DEMO_CONFIRM_DATABASE=hookyard_api_development \
ADMIN_DEMO_ATTEMPT_COUNT=100000 \
bundle exec rake admin:demo:seed
```

### Render Free (no shell)

Render Free has no shell, so drive the task with a one-off deploy of the same image: point the service's
start command (or a temporary pre-deploy command) at `bundle exec rake admin:demo:seed`. The task is
guarded and idempotent, so an accidental extra boot is harmless.

1. Set `HOOKYARD_DEMO_SEED=1`, `DEMO_ADMIN_PASSWORD`, `ADMIN_DEMO_CONFIRM_DATABASE=<database name>`,
   `ADMIN_DEMO_ATTEMPT_COUNT=100000` and `ADMIN_DEMO_DRY_RUN=1`.
2. Deploy once and read the dry run in the logs: current demo attempts, requested target, additional
   records, current database size, estimated additional storage and projected final size.
3. Set `ADMIN_DEMO_DRY_RUN=0` and deploy again to write.
4. Remove `HOOKYARD_DEMO_SEED` (or set it to `0`) so later boots do nothing.

`DEMO_ADMIN_PASSWORD` is only required for a write run; a dry run needs neither a password nor a
database confirmation.

### Incremental scaling

`ADMIN_DEMO_ATTEMPT_COUNT` is the **total** demo delivery-attempt target, not a delta (default `100000`,
maximum `200000`):

- first run with `100000` creates about 100000 demo attempts;
- rerunning with `100000` inserts nothing;
- raising it to `150000` adds only the missing records;
- lowering it again deletes nothing.

Existing ids, relationships, timestamps, signing secrets, status distribution and metric rollups are
preserved, and an interrupted run can simply be restarted.

### Safety limits

- Runs write in batches of 2000 messages to stay inside a 512 MB instance.
- `ADMIN_DEMO_MAX_DB_MB` (default `350`) aborts before writing when the *additional* records would push
  `pg_database_size` past the limit.
- `ADMIN_DEMO_CONFIRM_DATABASE` must match the target database name, so demo data cannot land in the
  wrong database by accident.
- A PostgreSQL advisory lock rejects a second concurrent seed.
- Only demo-namespaced rows are ever read or written (`demo-account-*@hookyard.test`, `demo:project:`,
  `demo:endpoint:`, `demo:event:`).

## License

Licensed under the MIT license, see the separate [LICENSE.md](./LICENSE.md) file.
