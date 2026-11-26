require 'rails_helper'

# Second connection to the same database so the advisory lock guard can be exercised from another session.
class AdminDemoSeederLockHolder < ActiveRecord::Base
end

describe AdminDemo::Seeder do
  let(:attempt_count) { 2_000 }
  let(:admin_password) { 'demo-password-123' }
  let(:database_name) { ActiveRecord::Base.connection.select_value('SELECT current_database()') }

  def seed_demo(attempts: attempt_count, **options)
    described_class.call(
      attempt_count: attempts,
      admin_password: admin_password,
      database_confirmation: database_name,
      **options
    )
  end

  def preview_demo(attempts: attempt_count, **options)
    described_class.call(attempt_count: attempts, dry_run: true, **options)
  end

  def demo_messages
    Message.where(event_id: Event.where("idempotency_key LIKE 'demo:event:%'").select(:id))
  end

  def demo_endpoints
    Endpoint.where("name LIKE 'demo:endpoint:%'")
  end

  def demo_attempts
    DeliveryAttempt.where(message_id: demo_messages.select(:id))
  end

  describe '.call' do
    it 'requires an admin password' do
      expect { described_class.call(attempt_count: attempt_count, database_confirmation: database_name) }
        .to raise_error(ArgumentError, /admin_password/)
    end

    it 'inserts namespaced demo accounts, projects, endpoints and deliveries' do
      report = seed_demo
      inserted = report[:inserted]

      expect(inserted.values.sum).to be_positive
      expect(User.where("email LIKE 'demo-account-%@hookyard.test'").count).to be >= 1
      expect(Project.where("name LIKE 'demo:project:%'").count).to be >= 1
      expect(Endpoint.where("name LIKE 'demo:endpoint:%'").count).to be >= 1
      expect(demo_messages.count).to be_positive
    end

    it 'creates a demo system administrator and support accounts that can sign in' do
      seed_demo

      admin = User.find_by(email: AdminDemo::Seeder::ADMIN_EMAIL)
      expect(admin.confirmed_at).to be_present
      expect(admin.valid_password?(admin_password)).to be(true)
      expect(admin).to be_admin

      AdminDemo::Seeder::SUPPORT_EMAILS.each do |email|
        expect(User.find_by(email: email)).to be_support
      end
    end

    it 'spreads demo data over the last thirty days' do
      seed_demo

      expect(demo_messages.minimum(:created_at)).to be > 31.days.ago
      expect(demo_endpoints.maximum(:created_at)).to be <= Time.current
      expect(Project.where("name LIKE 'demo:project:%'").maximum(:created_at)).to be <= Time.current
    end

    it 'covers terminal deliveries, held deliveries and failure categories' do
      seed_demo

      expect(demo_messages.group(:status).count.keys).to contain_exactly('failed', 'pending', 'succeeded')
      expect(demo_messages.held.where.not(status: Message::PENDING_STATUS)).to be_empty

      [
        Webhooks::FailureCategory::DESTINATION_REJECTED,
        Webhooks::FailureCategory::TIMEOUT,
        Webhooks::FailureCategory::NETWORK,
        Webhooks::FailureCategory::HTTP_ERROR,
        Webhooks::FailureCategory::INTERRUPTED
      ].each do |category|
        expect(Admin::DeliveriesQuery.call(demo_messages, failure_category: category,
                                                          from: 31.days.ago.iso8601).to_a).to be_present
      end
    end

    it 'keeps demo messages out of delivery cron scopes' do
      seed_demo
      cutoff = Time.current + 1.day

      expect(demo_messages.delivering).to be_empty
      expect(demo_messages.pending_without_retry_before(cutoff)).to be_empty
      expect(demo_messages.due_for_delivery(cutoff)).to be_empty
      expect(demo_messages.with_expired_lease(cutoff)).to be_empty
    end

    it 'does not enqueue circuit probe jobs for demo endpoints' do
      expect(CircuitProbes::RunJob).not_to receive(:perform_later)

      seed_demo

      expect(demo_endpoints.circuit_open).to be_empty
      expect(demo_endpoints.where.not(circuit_next_probe_at: nil)).to be_empty
      expect(demo_endpoints.probe_due(Time.current)).to be_empty
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == CircuitProbes::RunJob }).to be_empty
    end

    it 'never enqueues background jobs or outbound webhook requests' do
      expect(Webhooks::HttpClient).not_to receive(:new)
      usage_period_count = UserUsagePeriod.count

      seed_demo(attempts: 1_500)

      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
      expect(UserUsagePeriod.count).to eq(usage_period_count)
    end

    it 'gives every active non-archived demo endpoint exactly one active signing secret' do
      seed_demo

      demo_endpoints.active.not_archived.find_each do |endpoint|
        expect(endpoint.endpoint_signing_secrets.where(retired_at: nil).count).to eq(1)
      end
    end

    it 'seeds delivery attempts near the requested target and reports actual inserted counts' do
      report = seed_demo

      expect(demo_attempts.count).to eq(report[:inserted][:delivery_attempts])
      expect(report[:inserted][:delivery_attempts]).to be_within(attempt_count * 0.02).of(attempt_count)
      expect(report[:inserted][:signing_secrets]).to eq(demo_endpoints.active.not_archived.count)
    end

    it 'covers disabled and healthy endpoints' do
      seed_demo

      expect(demo_endpoints.group(:circuit_state).count.keys)
        .to contain_exactly('disabled', 'enabled')
    end

    it 'seeds disabled demo endpoints with a resolved circuit history' do
      seed_demo

      demo_endpoints.disabled.find_each do |endpoint|
        expect(endpoint.circuit_opened_at).to be_present
        expect(endpoint.circuit_disable_at).to be_present
        expect(endpoint.circuit_disable_at).to be > endpoint.circuit_opened_at
        expect(endpoint.circuit_disable_at).to be <= Time.current
        expect(endpoint.circuit_next_probe_at).to be_nil
      end
    end

    it 'seeds short redacted body samples for a representative subset only' do
      seed_demo
      attempts = demo_attempts

      with_request_body = attempts.where.not(request_body: nil)
      with_response_body = attempts.where.not(response_body: nil)

      expect(with_request_body.count).to be_positive
      expect(with_response_body.count).to be_positive
      expect(with_request_body.count).to be < attempts.count
      expect(with_response_body.count).to be < attempts.count
      expect(with_request_body.where('octet_length(request_body) > 256').count).to eq(0)
      expect(with_response_body.where('octet_length(response_body) > 256').count).to eq(0)
      expect(with_request_body.limit(10).pluck(:request_body)).to all(include('demo'))
      expect(attempts.where("request_headers::text LIKE '%secret%'").count).to eq(0)
      expect(attempts.where("request_headers::text LIKE '%token%'").count).to eq(0)
      expect(attempts.where("request_headers::text LIKE '%signature%'").count).to eq(0)
    end

    it 'populates delivery metric rollups that match completed demo attempts' do
      seed_demo

      expect(DeliveryMetric.count).to be_positive
      expect(DeliveryMetric.sum(:attempts_count)).to eq(demo_attempts.where.not(metrics_recorded_at: nil).count)
      expect(DeliveryMetric.sum(:successes_count)).to eq(demo_attempts.where(response_status: 200..299).count)
    end

    it 'is idempotent' do
      seed_demo

      expect(seed_demo[:inserted].values.sum).to eq(0)
    end
  end

  describe 'execution guards' do
    it 'rejects an attempt count above the supported maximum' do
      expect { seed_demo(attempts: described_class::ATTEMPT_MAXIMUM + 1) }
        .to raise_error(AdminDemo::Seeder::InvalidAttemptCountError, /#{described_class::ATTEMPT_MAXIMUM}/)
    end

    it 'rejects a non-positive attempt count' do
      expect { seed_demo(attempts: 0) }.to raise_error(AdminDemo::Seeder::InvalidAttemptCountError)
    end

    it 'refuses to write without an explicit database confirmation' do
      expect { described_class.call(attempt_count: 1_000, admin_password: admin_password) }
        .to raise_error(AdminDemo::Seeder::DatabaseTargetError, /ADMIN_DEMO_CONFIRM_DATABASE/)

      expect(User.where("email LIKE 'demo-account-%'")).to be_empty
      expect(demo_messages).to be_empty
    end

    it 'refuses to write when the projected database size exceeds the limit' do
      expect { seed_demo(attempts: 1_000, max_database_size_mb: 0.001) }
        .to raise_error(AdminDemo::Seeder::DatabaseSizeExceededError, /limit/)

      expect(User.where("email LIKE 'demo-account-%'")).to be_empty
      expect(demo_messages).to be_empty
      expect(DeliveryMetric.count).to eq(0)
    end

    it 'charges only the additional records, not the whole dataset' do
      seed_demo(attempts: 1_000)
      preview = preview_demo(attempts: 1_000)
      limit_mb = (preview[:database][:current_bytes] + (0.5 * described_class::MEGABYTE)) / described_class::MEGABYTE.to_f

      report = seed_demo(attempts: 1_000, max_database_size_mb: limit_mb)

      expect(preview[:pending][:delivery_attempts]).to eq(0)
      expect(preview[:database][:growth_bytes]).to eq(0)
      expect(report[:inserted].values.sum).to eq(0)
    end

    it 'refuses a second concurrent run while another session holds the execution lock' do
      AdminDemoSeederLockHolder.establish_connection(ActiveRecord::Base.connection_db_config)
      AdminDemoSeederLockHolder.connection.execute(
        "SELECT pg_advisory_lock(#{described_class::EXECUTION_LOCK_KEY})"
      )

      expect { seed_demo(attempts: 1_000) }
        .to raise_error(AdminDemo::Seeder::ConcurrentSeedError, /already running/)
    ensure
      AdminDemoSeederLockHolder.remove_connection
    end

    it 'releases the execution lock when a run aborts' do
      expect { seed_demo(attempts: 1_000, max_database_size_mb: 0.001) }
        .to raise_error(AdminDemo::Seeder::DatabaseSizeExceededError)

      AdminDemoSeederLockHolder.establish_connection(ActiveRecord::Base.connection_db_config)
      acquired = AdminDemoSeederLockHolder.connection.select_value(
        "SELECT pg_try_advisory_lock(#{described_class::EXECUTION_LOCK_KEY})"
      )

      expect(acquired).to be(true)
    ensure
      AdminDemoSeederLockHolder.remove_connection
    end
  end

  describe 'dry run' do
    it 'reports the current dataset, the additional records and the projected size without writing' do
      inserted = seed_demo(attempts: 1_000)[:inserted][:delivery_attempts]
      message_count = demo_messages.count

      report = preview_demo(attempts: 1_500)
      database = report[:database]

      expect(report[:dry_run]).to be(true)
      expect(report[:existing][:delivery_attempts]).to eq(inserted)
      expect(report[:requested_attempt_count]).to eq(1_500)
      expect(report[:pending][:delivery_attempts]).to be_positive
      expect(report[:pending][:messages]).to be_positive
      expect(report[:pending][:events]).to eq(report[:pending][:messages])
      expect(database[:growth_bytes])
        .to eq(report[:pending][:delivery_attempts] * described_class::ESTIMATED_BYTES_PER_ATTEMPT)
      expect(database[:projected_bytes]).to eq(database[:current_bytes] + database[:growth_bytes])
      expect(database[:limit_bytes]).to eq(described_class::DEFAULT_DATABASE_LIMIT_MB * described_class::MEGABYTE)

      expect(demo_messages.count).to eq(message_count)
      expect(report[:inserted].values.sum).to eq(0)
    end

    it 'needs neither a password nor a database confirmation' do
      expect { described_class.call(attempt_count: 1_000, dry_run: true) }.not_to raise_error
    end
  end

  describe 'incremental scaling' do
    it 'grows the dataset to the requested total without duplicating or rewriting existing records' do
      first = seed_demo(attempts: 1_000)
      preserved_messages = demo_messages.order(:id).pluck(:id, :endpoint_id, :event_id, :status, :created_at)
      preserved_attempts = demo_attempts.order(:id).pluck(:id, :message_id, :created_at, :response_status)
      preserved_secrets = EndpointSigningSecret.current.where(endpoint_id: demo_endpoints.select(:id))
                                                   .order(:endpoint_id).pluck(:endpoint_id, :secret)

      second = seed_demo(attempts: 1_500)

      expect(second[:inserted][:delivery_attempts]).to be_positive
      expect(second[:final][:delivery_attempts])
        .to eq(first[:final][:delivery_attempts] + second[:inserted][:delivery_attempts])
      expect(second[:final][:delivery_attempts]).to eq(second[:targets][:delivery_attempts])
      expect(demo_messages.count).to be > preserved_messages.size

      message_ids = preserved_messages.map(&:first)
      expect(demo_messages.where(id: message_ids).order(:id).pluck(:id, :endpoint_id, :event_id, :status, :created_at))
        .to eq(preserved_messages)

      attempt_ids = preserved_attempts.map(&:first)
      expect(DeliveryAttempt.where(id: attempt_ids).order(:id).pluck(:id, :message_id, :created_at, :response_status))
        .to eq(preserved_attempts)

      endpoint_ids = preserved_secrets.map(&:first)
      expect(EndpointSigningSecret.current.where(endpoint_id: endpoint_ids).order(:endpoint_id).pluck(:endpoint_id, :secret))
        .to eq(preserved_secrets)

      expect(demo_attempts.group(:message_id, :attempt_number).having('COUNT(*) > 1').count).to be_empty
      expect(DeliveryMetric.sum(:attempts_count)).to eq(demo_attempts.where.not(metrics_recorded_at: nil).count)
    end

    it 'adds nothing when the target is already reached' do
      seed_demo(attempts: 1_500)
      message_count = demo_messages.count
      metric_total = DeliveryMetric.sum(:attempts_count)

      report = seed_demo(attempts: 1_500)

      expect(report[:inserted].values.sum).to eq(0)
      expect(demo_messages.count).to eq(message_count)
      expect(DeliveryMetric.sum(:attempts_count)).to eq(metric_total)
    end

    it 'keeps existing data when the requested target decreases' do
      seed_demo(attempts: 1_500)
      before = {
        messages: demo_messages.count,
        attempts: demo_attempts.count,
        endpoints: demo_endpoints.count,
        secrets: EndpointSigningSecret.current.count,
        metric_total: DeliveryMetric.sum(:attempts_count)
      }

      report = seed_demo(attempts: 1_000)

      expect(report[:pending][:delivery_attempts]).to eq(0)
      expect(report[:inserted].values.sum).to eq(0)
      expect(demo_messages.count).to eq(before[:messages])
      expect(demo_attempts.count).to eq(before[:attempts])
      expect(demo_endpoints.count).to eq(before[:endpoints])
      expect(EndpointSigningSecret.current.count).to eq(before[:secrets])
      expect(DeliveryMetric.sum(:attempts_count)).to eq(before[:metric_total])
    end

    it 'resumes and repairs an interrupted run' do
      seed_demo(attempts: 1_500)
      target_attempts = demo_attempts.count
      interrupted_ids = demo_messages.order(:id).limit(50).ids

      DeliveryAttempt.where(message_id: interrupted_ids).delete_all
      Message.where(id: interrupted_ids).delete_all

      expect(demo_messages.where(id: interrupted_ids)).to be_empty

      report = seed_demo(attempts: 1_500)

      expect(report[:inserted][:messages]).to eq(interrupted_ids.size)
      expect(report[:final][:delivery_attempts]).to eq(target_attempts)
      expect(demo_messages.where(id: interrupted_ids).count).to eq(interrupted_ids.size)
      expect(DeliveryMetric.sum(:attempts_count)).to eq(demo_attempts.where.not(metrics_recorded_at: nil).count)
    end
  end
end
