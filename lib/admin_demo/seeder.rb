module AdminDemo
  class Seeder
    ATTEMPT_DEFAULT = 200_000
    ATTEMPT_MAXIMUM = 200_000
    WINDOW_DAYS = 30
    BATCH_SIZE = 2_000
    PROGRESS_EVERY_BATCHES = 10
    MEGABYTE = 1024 * 1024
    DEFAULT_DATABASE_LIMIT_MB = 350
    ESTIMATED_BYTES_PER_ATTEMPT = 1_600
    EXECUTION_LOCK_KEY = 7_310_552_914_338_201

    EMAIL_DOMAIN = 'hookyard.test'
    ADMIN_EMAIL = "demo-admin@#{EMAIL_DOMAIN}"
    SUPPORT_EMAILS = (1..3).map { |index| "demo-support-#{index}@#{EMAIL_DOMAIN}" }.freeze

    PROJECT_PREFIX = 'demo:project:'
    ENDPOINT_PREFIX = 'demo:endpoint:'
    EVENT_PREFIX = 'demo:event:'

    PLATFORM_DIVISORS = { accounts: 100, projects: 100, endpoints: 50 }.freeze
    AVERAGE_ATTEMPTS_PER_MESSAGE = 1.4
    BODY_SAMPLE_EVERY = 20
    SIGNING_SECRET_VERSION = 1

    REQUEST_BODY_SAMPLE = '{"event":"demo.created","demo":true}'
    RESPONSE_BODY_SAMPLE = '{"received":true}'

    FIRST_NAMES = %w[Ada Alan Grace Linus Margaret Barbara Dennis Ken Tim Edsger].freeze
    LAST_NAMES = %w[Lovelace Turing Hopper Torvalds Hamilton Liskov Ritchie Thompson Berners-Lee Dijkstra].freeze
    EVENT_TYPES = %w[order.created order.updated invoice.paid user.signup payment.failed].freeze
    SUCCESS_STATUSES = [200, 201, 202, 204].freeze

    STATUS_BUCKETS = (
      Array.new(65, :succeeded) + Array.new(25, :failed) + Array.new(10, :held)
    ).freeze

    ATTEMPT_COUNT_FOR = { succeeded: 1, failed: 3, held: 0 }.freeze
    ATTEMPTS_PER_STATUS_CYCLE = STATUS_BUCKETS.sum { |status| ATTEMPT_COUNT_FOR.fetch(status, 0) }

    CIRCUIT_BUCKETS = (
      %w[enabled disabled] + Array.new(90, 'enabled') + Array.new(6, 'disabled')
    ).freeze

    FAILURE_BUCKETS = (
      Array.new(40, :http_error) + Array.new(25, :timeout) + Array.new(20, :network) +
      Array.new(10, :destination_rejected) + Array.new(5, :interrupted)
    ).freeze

    FAILURE_EVIDENCE = {
      http_error: [[500, nil], [502, nil], [503, nil], [404, nil], [429, nil], [422, nil]],
      timeout: [[nil, 'Net::ReadTimeout'], [nil, 'Net::OpenTimeout'], [nil, 'Timeout::Error']],
      network: [[nil, 'Errno::ECONNREFUSED'], [nil, 'SocketError'], [nil, 'Errno::EHOSTUNREACH']],
      destination_rejected: [[nil, 'Webhooks::DestinationResolver::NotPubliclyRoutable']],
      interrupted: [[nil, 'DeliveryLeaseExpired']]
    }.freeze

    ROLLUP_SQL = <<~SQL.squish
      INSERT INTO delivery_metrics (id, project_id, day, attempts_count, successes_count, failures_count, created_at, updated_at)
      SELECT gen_random_uuid(), rollup.project_id, rollup.day, rollup.attempts_count, rollup.successes_count,
             rollup.failures_count, NOW(), NOW()
      FROM (
        SELECT endpoints.project_id AS project_id,
               (delivery_attempts.created_at AT TIME ZONE 'UTC')::date AS day,
               COUNT(*) AS attempts_count,
               COUNT(*) FILTER (WHERE delivery_attempts.response_status BETWEEN 200 AND 299) AS successes_count,
               COUNT(*) FILTER (
                 WHERE delivery_attempts.response_status IS NULL
                    OR NOT (delivery_attempts.response_status BETWEEN 200 AND 299)
               ) AS failures_count
        FROM delivery_attempts
        INNER JOIN messages ON messages.id = delivery_attempts.message_id
        INNER JOIN endpoints ON endpoints.id = messages.endpoint_id
        INNER JOIN events ON events.id = messages.event_id
        WHERE events.idempotency_key LIKE ?
          AND (
            delivery_attempts.response_status IS NOT NULL
            OR (delivery_attempts.error_type IS NOT NULL AND BTRIM(delivery_attempts.error_type) <> '')
          )
        GROUP BY endpoints.project_id, (delivery_attempts.created_at AT TIME ZONE 'UTC')::date
      ) AS rollup
      ON CONFLICT (project_id, day) DO UPDATE SET
        attempts_count = EXCLUDED.attempts_count,
        successes_count = EXCLUDED.successes_count,
        failures_count = EXCLUDED.failures_count,
        updated_at = NOW()
      WHERE delivery_metrics.attempts_count <> EXCLUDED.attempts_count
         OR delivery_metrics.successes_count <> EXCLUDED.successes_count
         OR delivery_metrics.failures_count <> EXCLUDED.failures_count
    SQL

    class Error < StandardError; end
    class InvalidAttemptCountError < Error; end
    class DatabaseSizeExceededError < Error; end
    class ConcurrentSeedError < Error; end
    class DatabaseTargetError < Error; end

    def self.call(...)
      new(...).call
    end

    def initialize(attempt_count: ATTEMPT_DEFAULT, admin_password: nil, dry_run: false,
                   database_confirmation: nil, max_database_size_mb: nil, now: Time.current)
      @attempt_count = parse_attempt_count(attempt_count)
      @admin_password = admin_password.to_s
      @dry_run = dry_run
      @database_confirmation = database_confirmation.to_s.strip
      @max_database_size_mb = Float(max_database_size_mb.presence || DEFAULT_DATABASE_LIMIT_MB)
      @now = now
      @window_start = now - WINDOW_DAYS.days

      raise ArgumentError, 'admin_password must be present' if @admin_password.blank? && !@dry_run
    end

    def call
      @counts = target_counts

      return build_report if @dry_run

      verify_database_target!

      with_execution_lock do
        report = build_report
        verify_database_size!(report)
        report[:inserted] = seed
        report[:final] = existing_demo_counts
        report
      end
    end

    private

    attr_reader :counts

    def parse_attempt_count(value)
      count = Integer(value.to_s, exception: false)
      return count if count&.between?(1, ATTEMPT_MAXIMUM)

      raise InvalidAttemptCountError,
            "DEMO_DELIVERY_ATTEMPTS_TARGET must be an integer between 1 and #{ATTEMPT_MAXIMUM}"
    end

    def target_counts
      {
        accounts: [(@attempt_count / PLATFORM_DIVISORS[:accounts]).round, 1].max,
        projects: [(@attempt_count / PLATFORM_DIVISORS[:projects]).round, 1].max,
        endpoints: [(@attempt_count / PLATFORM_DIVISORS[:endpoints]).round, 1].max,
        messages: [(@attempt_count / AVERAGE_ATTEMPTS_PER_MESSAGE).round, 1].max
      }
    end

    def build_report
      existing = existing_demo_counts
      targets = target_snapshot
      pending = pending_counts(targets, existing)

      {
        dry_run: @dry_run,
        database: database_snapshot(pending),
        requested_attempt_count: @attempt_count,
        targets: targets,
        existing: existing,
        pending: pending,
        inserted: empty_inserted_counts,
        final: nil
      }
    end

    def target_snapshot
      {
        accounts: counts[:accounts],
        projects: counts[:projects],
        endpoints: counts[:endpoints],
        signing_secrets: signing_secret_target_count,
        events: counts[:messages],
        messages: counts[:messages],
        delivery_attempts: expected_attempt_count,
        delivery_metrics: counts[:projects] * (WINDOW_DAYS + 1)
      }
    end

    def existing_demo_counts
      {
        accounts: User.where('email LIKE ?', "demo-account-%@#{EMAIL_DOMAIN}").count,
        projects: demo_projects.count,
        endpoints: demo_endpoints.count,
        signing_secrets: EndpointSigningSecret.current.where(endpoint_id: demo_endpoints.select(:id)).count,
        events: demo_events.count,
        messages: demo_messages.count,
        delivery_attempts: DeliveryAttempt.where(message_id: demo_messages.select(:id)).count,
        delivery_metrics: DeliveryMetric.where(project_id: demo_projects.select(:id)).count
      }
    end

    def pending_counts(targets, existing)
      targets.each_with_object({}) do |(key, target), pending|
        pending[key] = [target - existing.fetch(key), 0].max
      end
    end

    def database_snapshot(pending)
      current_bytes = current_database_bytes
      growth_bytes = pending[:delivery_attempts] * ESTIMATED_BYTES_PER_ATTEMPT

      {
        name: current_database_name,
        environment: Rails.env,
        current_bytes: current_bytes,
        growth_bytes: growth_bytes,
        projected_bytes: current_bytes + growth_bytes,
        limit_bytes: (@max_database_size_mb * MEGABYTE).to_i
      }
    end

    def empty_inserted_counts
      {
        accounts: 0,
        projects: 0,
        endpoints: 0,
        signing_secrets: 0,
        events: 0,
        messages: 0,
        delivery_attempts: 0,
        delivery_metrics: 0
      }
    end

    def current_database_name
      @current_database_name ||= ActiveRecord::Base.connection.select_value('SELECT current_database()')
    end

    def current_database_bytes
      ActiveRecord::Base.connection.select_value('SELECT pg_database_size(current_database())').to_i
    end

    def verify_database_target!
      return if @database_confirmation == current_database_name

      raise DatabaseTargetError,
            "set ADMIN_DEMO_CONFIRM_DATABASE=#{current_database_name} to confirm the target database"
    end

    def verify_database_size!(report)
      database = report[:database]
      return if database[:projected_bytes] <= database[:limit_bytes]

      raise DatabaseSizeExceededError,
            "estimated database size #{human_size(database[:projected_bytes])} would exceed the " \
            "#{human_size(database[:limit_bytes])} limit; lower ADMIN_DEMO_ATTEMPT_COUNT or raise ADMIN_DEMO_MAX_DB_MB"
    end

    def with_execution_lock
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        unless connection.select_value("SELECT pg_try_advisory_lock(#{EXECUTION_LOCK_KEY})")
          raise ConcurrentSeedError, 'another admin demo seed is already running'
        end

        begin
          yield
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{EXECUTION_LOCK_KEY})")
        end
      end
    end

    def seed
      {
        accounts: seed_accounts,
        projects: seed_projects,
        endpoints: seed_endpoints,
        signing_secrets: seed_signing_secrets,
        **seed_deliveries
      }
    end

    def seed_accounts
      rows = Array.new(counts[:accounts]) { |index| account_row(index) } + staff_account_rows
      inserted = insert_rows(User, rows)
      assign_staff_roles

      inserted
    end

    def seed_projects
      inserted = insert_rows(Project, Array.new(counts[:projects]) { |index| project_row(index) })
      seed_project_owners

      inserted
    end

    def seed_endpoints
      insert_rows(Endpoint, Array.new(counts[:endpoints]) { |index| endpoint_row(index) })
    end

    def seed_signing_secrets
      missing_secret_endpoints.pluck(:id, :created_at).sum do |endpoint_id, created_at|
        EndpointSigningSecret.create!(
          endpoint_id: endpoint_id,
          version: SIGNING_SECRET_VERSION,
          secret: signing_secret_for(endpoint_id),
          created_at: created_at,
          updated_at: created_at
        )
        1
      end
    end

    def missing_secret_endpoints
      Endpoint.where(id: demo_endpoint_ids).active.not_archived
              .where.not(id: EndpointSigningSecret.current.select(:endpoint_id))
    end

    def seed_deliveries
      inserted = { events: 0, messages: 0, delivery_attempts: 0 }
      processed_batches = 0

      (0...counts[:messages]).step(BATCH_SIZE) do |start|
        finish = [start + BATCH_SIZE, counts[:messages]].min
        events, messages, attempts = delivery_rows(start, finish)

        inserted[:events] += insert_rows(Event, events)
        inserted[:messages] += insert_rows(Message, messages)
        inserted[:delivery_attempts] += insert_rows(DeliveryAttempt, attempts)

        processed_batches += 1
        log_progress(finish) if (processed_batches % PROGRESS_EVERY_BATCHES).zero?
      end

      inserted.merge(delivery_metrics: seed_delivery_metrics)
    end

    def log_progress(processed_messages)
      Rails.logger.info("admin demo seed: processed #{processed_messages}/#{counts[:messages]} demo messages")
    end

    def seed_delivery_metrics
      DeliveryMetric.connection.exec_update(
        ActiveRecord::Base.sanitize_sql([ROLLUP_SQL, "#{EVENT_PREFIX}%"]),
        'admin demo delivery metric rollup'
      )
    end

    def insert_rows(model, rows)
      return 0 if rows.empty?

      model.insert_all(rows, unique_by: :id, returning: :id, record_timestamps: false).rows.size
    end

    def delivery_rows(start, finish)
      events = []
      messages = []
      attempts = []

      (start...finish).each do |index|
        created_at = timestamp_for("message/#{index}")
        message_id = demo_uuid("message/#{index}")
        status = STATUS_BUCKETS[index % STATUS_BUCKETS.size]
        endpoint_index = endpoint_index_for(index, status)
        endpoint_id = demo_uuid("endpoint/#{endpoint_index}")

        events << event_row(index, created_at, endpoint_index)
        messages << message_row(message_id, endpoint_id, endpoint_index, status, index, created_at)
        attempts.concat(attempt_rows(message_id, status, index, created_at))
      end

      [events, messages, attempts]
    end

    def account_row(index)
      created_at = timestamp_for("account/#{index}")
      confirmed = !(index % 10).zero?

      {
        id: demo_uuid("account/#{index}"),
        email: "demo-account-#{index}@#{EMAIL_DOMAIN}",
        encrypted_password: password_digest,
        first_name: FIRST_NAMES[index % FIRST_NAMES.size],
        last_name: LAST_NAMES[index % LAST_NAMES.size],
        confirmed_at: confirmed ? created_at : nil,
        sign_in_count: index % 37,
        last_sign_in_at: confirmed ? clamp_to_now(created_at + 1.day) : nil,
        created_at: created_at,
        updated_at: created_at
      }
    end

    def staff_account_rows
      [ADMIN_EMAIL, *SUPPORT_EMAILS].each_with_index.map do |email, index|
        created_at = timestamp_for("staff/#{index}")

        {
          id: demo_uuid("staff/#{index}"),
          email: email,
          encrypted_password: password_digest,
          first_name: FIRST_NAMES[index % FIRST_NAMES.size],
          last_name: LAST_NAMES[index % LAST_NAMES.size],
          confirmed_at: created_at,
          sign_in_count: 0,
          last_sign_in_at: created_at,
          created_at: created_at,
          updated_at: created_at
        }
      end
    end

    def assign_staff_roles
      [ADMIN_EMAIL, *SUPPORT_EMAILS].each do |email|
        user = User.find_by(email: email)
        next if user.nil?

        role = email == ADMIN_EMAIL ? :admin : :support
        user.add_role(role) unless user.has_role?(role)
      end
    end

    def project_row(index)
      created_at = timestamp_for("project/#{index}")

      {
        id: demo_uuid("project/#{index}"),
        name: "#{PROJECT_PREFIX}#{index}",
        billing_owner_id: demo_uuid("account/#{index % counts[:accounts]}"),
        created_at: created_at,
        updated_at: created_at
      }
    end

    def seed_project_owners
      rows = Array.new(counts[:projects]) do |index|
        {
          id: demo_uuid("membership/#{index}"),
          project_id: demo_uuid("project/#{index}"),
          user_id: demo_uuid("account/#{index % counts[:accounts]}"),
          role: 'owner',
          created_at: timestamp_for("project/#{index}"),
          updated_at: timestamp_for("project/#{index}")
        }
      end

      insert_rows(ProjectMembership, rows)
    end

    def endpoint_row(index)
      circuit_state = CIRCUIT_BUCKETS[index % CIRCUIT_BUCKETS.size]
      created_at = timestamp_for("endpoint/#{index}")
      created_at = @window_start + (index % 5).days if circuit_state == 'disabled'
      opened_at = circuit_state == 'disabled' ? created_at + 2.days : nil

      {
        id: demo_uuid("endpoint/#{index}"),
        project_id: project_id_for_endpoint(index),
        name: "#{ENDPOINT_PREFIX}#{index}",
        url: endpoint_url(index),
        active: endpoint_active?(index),
        archived_at: endpoint_archived?(index) ? clamp_to_now(created_at + 1.day) : nil,
        event_types: index % 10 == 0 ? ['*'] : [EVENT_TYPES[index % EVENT_TYPES.size]],
        circuit_state: circuit_state,
        circuit_failure_count: circuit_state == 'enabled' ? 0 : 5 + (index % 5),
        circuit_opened_at: opened_at,
        circuit_disable_at: opened_at && clamp_to_now(opened_at + Webhooks::CircuitPolicy.disable_window),
        circuit_next_probe_at: nil,
        queued_message_count: 0,

        created_at: created_at,
        updated_at: created_at
      }
    end

    def endpoint_active?(index)
      !(index % 20).zero?
    end

    def endpoint_archived?(index)
      (index % 25).zero?
    end

    def signing_secret_target_count
      (0...counts[:endpoints]).count { |index| endpoint_active?(index) && !endpoint_archived?(index) }
    end

    def event_row(index, created_at, endpoint_index = nil)
      idempotency_key = "#{EVENT_PREFIX}#{index}"

      {
        id: demo_uuid("event/#{index}"),
        project_id: project_id_for_endpoint(endpoint_index || (index % counts[:endpoints])),
        event_type: EVENT_TYPES[index % EVENT_TYPES.size],
        payload: { 'demo' => true, 'index' => index },
        idempotency_key: idempotency_key,
        idempotency_fingerprint: Digest::SHA256.hexdigest(idempotency_key),
        created_at: created_at,
        updated_at: created_at
      }
    end

    def message_row(id, endpoint_id, endpoint_index, status, index, created_at)
      updated_at = clamp_to_now(created_at + 1.hour)

      {
        id: id,
        event_id: demo_uuid("event/#{index}"),
        endpoint_id: endpoint_id,
        status: status == :held ? Message::PENDING_STATUS : status.to_s,
        attempt_count: ATTEMPT_COUNT_FOR.fetch(status, 0),
        queued_at: nil,
        held_at: status == :held ? updated_at : nil,
        hold_reason: status == :held ? hold_reason_for_endpoint(endpoint_index) : nil,
        next_retry_at: nil,
        terminal_at: terminal_status?(status) ? updated_at : nil,
        delivery_lease_expires_at: nil,
        created_at: created_at,
        updated_at: updated_at
      }
    end

    def attempt_rows(message_id, status, index, created_at)
      Array.new(ATTEMPT_COUNT_FOR.fetch(status, 0)) do |offset|
        number = offset + 1
        at = clamp_to_now(created_at + (number * 5).minutes)
        evidence = attempt_evidence(status, index, number)

        attempt_row(message_id, index, number, evidence, at)
      end
    end

    def attempt_row(message_id, index, number, evidence, at)
      {
        id: demo_uuid("attempt/#{index}/#{number}"),
        message_id: message_id,
        attempt_number: number,
        request_id: "req_#{demo_uuid("request/#{index}/#{number}")}",
        webhook_id: "msg_#{message_id}",
        signing_secret_version: 1,
        signed_at: at,
        request_url: endpoint_url(index),
        http_method: 'POST',
        request_headers: { 'content-type' => 'application/json' },
        request_body: body_sample?(index) ? REQUEST_BODY_SAMPLE : nil,
        response_status: evidence[:response_status],
        response_headers: {},
        response_body: body_sample?(index) && evidence[:response_status] ? RESPONSE_BODY_SAMPLE : nil,
        duration_ms: 50 + (index % 900),
        error_type: evidence[:error_type],
        error_message: evidence[:error_type] ? "demo failure: #{evidence[:error_type]}" : nil,
        metrics_recorded_at: terminal_attempt?(evidence) ? at : nil,
        created_at: at,
        updated_at: at
      }
    end

    def attempt_evidence(status, index, number)
      return { response_status: SUCCESS_STATUSES[index % SUCCESS_STATUSES.size], error_type: nil } if status == :succeeded
      return { response_status: nil, error_type: nil } if %i[delivering pending].include?(status)

      category = FAILURE_BUCKETS[pseudo_random("category/#{index}/#{number}") % FAILURE_BUCKETS.size]
      options = FAILURE_EVIDENCE.fetch(category)
      response_status, error_type = options[pseudo_random("evidence/#{index}/#{number}") % options.size]

      { response_status: response_status, error_type: error_type }
    end

    def terminal_attempt?(evidence)
      evidence[:response_status].present? || evidence[:error_type].present?
    end

    def body_sample?(index)
      (index % BODY_SAMPLE_EVERY).zero?
    end

    def terminal_status?(status)
      %i[succeeded failed].include?(status)
    end

    def endpoint_url(index)
      "https://demo-#{index % counts[:endpoints]}.example.test/hooks"
    end

    def endpoint_index_for(index, status = nil)
      return held_endpoint_index_for(index) if status == :held

      index % counts[:endpoints]
    end

    def held_endpoint_index_for(index)
      held_endpoint_indexes[index % held_endpoint_indexes.size]
    end

    def held_endpoint_indexes
      @held_endpoint_indexes ||= (0...counts[:endpoints]).reject do |index|
        CIRCUIT_BUCKETS[index % CIRCUIT_BUCKETS.size] == 'enabled'
      end
    end

    def hold_reason_for_endpoint(_endpoint_index)
      Webhooks::CircuitPolicy::HOLD_REASONS.fetch(:disabled)
    end

    def project_id_for_endpoint(endpoint_index)
      demo_uuid("project/#{endpoint_index % counts[:projects]}")
    end

    def demo_endpoint_ids
      @demo_endpoint_ids ||= Array.new(counts[:endpoints]) { |index| demo_uuid("endpoint/#{index}") }
    end

    def demo_projects
      Project.where('name LIKE ?', "#{PROJECT_PREFIX}%")
    end

    def demo_endpoints
      Endpoint.where('name LIKE ?', "#{ENDPOINT_PREFIX}%")
    end

    def demo_events
      Event.where('idempotency_key LIKE ?', "#{EVENT_PREFIX}%")
    end

    def demo_messages
      Message.where(event_id: demo_events.select(:id))
    end

    def expected_attempt_count
      cycles, remainder = counts[:messages].divmod(STATUS_BUCKETS.size)
      remainder_attempts = STATUS_BUCKETS.first(remainder).sum { |status| ATTEMPT_COUNT_FOR.fetch(status, 0) }

      (cycles * ATTEMPTS_PER_STATUS_CYCLE) + remainder_attempts
    end

    def timestamp_for(label)
      @window_start + (pseudo_random(label) % WINDOW_DAYS.days.to_i)
    end

    def pseudo_random(label)
      Digest::SHA256.hexdigest("#{EMAIL_DOMAIN}/#{label}").to_i(16)
    end

    def clamp_to_now(time)
      time > @now ? @now : time
    end

    def demo_uuid(label)
      hex = Digest::SHA256.hexdigest("hookyard-admin-demo/#{label}")

      "#{hex[0, 8]}-#{hex[8, 4]}-5#{hex[13, 3]}-a#{hex[17, 3]}-#{hex[20, 12]}"
    end

    def password_digest
      @password_digest ||= User.new(password: @admin_password).encrypted_password
    end

    def signing_secret_for(endpoint_id)
      digest = Digest::SHA256.digest("hookyard-admin-demo/signing-secret/#{endpoint_id}")
      "whsec_#{Base64.strict_encode64(digest).first(32)}"
    end

    def human_size(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes)
    end
  end
end
