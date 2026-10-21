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

## License

Licensed under the MIT license, see the separate [LICENSE.md](./LICENSE.md) file.
