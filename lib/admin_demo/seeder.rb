module AdminDemo
  class Seeder
    ATTEMPT_DEFAULT = 200_000
    WINDOW_DAYS = 30
    BATCH_SIZE = 5_000
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

    def self.call(...)
      new(...).call
    end

    def initialize(attempt_count: ATTEMPT_DEFAULT, admin_password:, now: Time.current)
      @attempt_count = Integer(attempt_count)
      @admin_password = admin_password.to_s
      @now = now
      raise ArgumentError, 'attempt_count must be a positive integer' unless @attempt_count.positive?
      raise ArgumentError, 'admin_password must be present' if @admin_password.blank?

      @window_start = now - WINDOW_DAYS.days
      @metrics = Hash.new { |hash, key| hash[key] = { attempts_count: 0, successes_count: 0, failures_count: 0 } }
    end

    def call
      @counts = target_counts

      {
        accounts: seed_accounts,
        projects: seed_projects,
        endpoints: seed_endpoints,
        signing_secrets: seed_signing_secrets,
        **seed_deliveries
      }
    end

    private

    attr_reader :counts

    def target_counts
      {
        accounts: [(@attempt_count / PLATFORM_DIVISORS[:accounts]).round, 1].max,
        projects: [(@attempt_count / PLATFORM_DIVISORS[:projects]).round, 1].max,
        endpoints: [(@attempt_count / PLATFORM_DIVISORS[:endpoints]).round, 1].max,
        messages: [(@attempt_count / AVERAGE_ATTEMPTS_PER_MESSAGE).round, 1].max
      }
    end

    def seed_accounts
      rows = Array.new(counts[:accounts]) { |index| account_row(index) } + staff_account_rows
      inserted = User.insert_all(rows, unique_by: :id, returning: :id, record_timestamps: false).rows.size
      assign_staff_roles

      inserted
    end

    def seed_projects
      rows = Array.new(counts[:projects]) { |index| project_row(index) }
      inserted = Project.insert_all(rows, unique_by: :id, returning: :id, record_timestamps: false).rows.size
      seed_project_owners

      inserted
    end

    def seed_endpoints
      rows = Array.new(counts[:endpoints]) { |index| endpoint_row(index) }
      Endpoint.insert_all(rows, unique_by: :id, returning: :id, record_timestamps: false).rows.size
    end

    def seed_signing_secrets
      created = 0

      Endpoint.active.not_archived.find_each do |endpoint|
        secret = EndpointSigningSecret.where(endpoint_id: endpoint.id, retired_at: nil).first_or_initialize
        next if secret.persisted?

        secret.assign_attributes(
          version: SIGNING_SECRET_VERSION,
          secret: signing_secret_for(endpoint.id),
          created_at: endpoint.created_at,
          updated_at: endpoint.created_at
        )
        secret.save!
        created += 1
      end

      created
    end

    def seed_deliveries
      inserted = { events: 0, messages: 0, delivery_attempts: 0 }

      (0...counts[:messages]).step(BATCH_SIZE) do |start|
        events, messages, attempts = delivery_rows(start, [start + BATCH_SIZE, counts[:messages]].min)
        inserted[:events] += insert_rows(Event, events)
        inserted[:messages] += insert_rows(Message, messages)
        inserted[:delivery_attempts] += insert_rows(DeliveryAttempt, attempts)
      end

      inserted.merge(delivery_metrics: seed_delivery_metrics)
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
        active: !(index % 20).zero?,
        archived_at: (index % 25).zero? ? clamp_to_now(created_at + 1.day) : nil,
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

        record_metric(project_id_for_endpoint(index % counts[:endpoints]), at, status) if terminal_status?(status)

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

    def record_metric(project_id, at, status)
      day = at.utc.to_date
      key = [project_id, day]

      @metrics[key][:attempts_count] += 1
      status == :succeeded ? @metrics[key][:successes_count] += 1 : @metrics[key][:failures_count] += 1
    end

    def seed_delivery_metrics
      rows = @metrics.map do |(project_id, day), counts|
        {
          id: demo_uuid("delivery-metric/#{project_id}/#{day}"),
          project_id: project_id,
          day: day,
          attempts_count: counts[:attempts_count],
          successes_count: counts[:successes_count],
          failures_count: counts[:failures_count],
          created_at: @now,
          updated_at: @now
        }
      end

      insert_rows(DeliveryMetric, rows)
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
  end
end
