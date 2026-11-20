require 'rails_helper'

describe AdminDemo::Seeder do
  let(:attempt_count) { 2_000 }
  let(:admin_password) { 'demo-password-123' }

  def seed_demo
    described_class.call(attempt_count: attempt_count, admin_password: admin_password)
  end

  def demo_messages
    Message.where(event_id: Event.where("idempotency_key LIKE 'demo:event:%'").select(:id))
  end

  def demo_endpoints
    Endpoint.where("name LIKE 'demo:endpoint:%'")
  end

  describe '.call' do
    it 'requires an admin password' do
      expect { described_class.call(attempt_count: attempt_count) }
        .to raise_error(ArgumentError, /admin_password/)
    end

    it 'inserts namespaced demo accounts, projects, endpoints and deliveries' do
      counts = seed_demo

      expect(counts.values.sum).to be_positive
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

    it 'gives every active non-archived demo endpoint exactly one active signing secret' do
      seed_demo

      demo_endpoints.active.not_archived.find_each do |endpoint|
        expect(endpoint.endpoint_signing_secrets.where(retired_at: nil).count).to eq(1)
      end
    end

    it 'seeds delivery attempts near the requested target and reports actual inserted counts' do
      counts = seed_demo

      attempts = DeliveryAttempt.where(message_id: demo_messages.select(:id))
      expect(attempts.count).to eq(counts[:delivery_attempts])
      expect(counts[:delivery_attempts]).to be_within(attempt_count * 0.02).of(attempt_count)
      expect(counts[:signing_secrets]).to eq(demo_endpoints.active.not_archived.count)
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
      attempts = DeliveryAttempt.where(message_id: demo_messages.select(:id))

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

      demo_attempts = DeliveryAttempt.where(message_id: demo_messages.select(:id))
      rollup_totals = DeliveryMetric.sum(:attempts_count)

      expect(DeliveryMetric.count).to be_positive
      expect(rollup_totals).to eq(
        demo_attempts.where.not(metrics_recorded_at: nil).count
      )
      expect(DeliveryMetric.sum(:successes_count)).to eq(
        demo_attempts.where(response_status: 200..299).count
      )
    end

    it 'is idempotent' do
      seed_demo

      expect(seed_demo.values.sum).to eq(0)
    end
  end
end
