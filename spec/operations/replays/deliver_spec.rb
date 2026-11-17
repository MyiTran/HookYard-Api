require 'rails_helper'

describe Replays::Deliver, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project, event_types: ['order.created']) }
  let(:event) { create(:event, project: project, event_type: 'order.created', payload: { 'order_id' => 'ord_1' }) }
  let(:message) { create(:message, event: event, endpoint: endpoint, status: :failed, terminal_at: Time.current) }
  let(:run) { create(:replay_run, project: project) }
  let(:item) do
    create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                         status: ReplayItem::QUEUED_STATUS)
  end
  let(:http_client) { double('http_client') }
  let(:operation) { described_class.new(http_client: http_client) }

  before { travel_to(Time.zone.local(2026, 1, 1, 12, 0, 0)) }

  def http_result(status: nil, error: nil, error_type: nil, headers: {}, body: nil, duration_ms: 12)
    Webhooks::HttpClient::Result.new(
      status: status,
      headers: headers,
      body: body || (status.nil? ? nil : 'response body'),
      duration_ms: duration_ms,
      error: error,
      error_type: error_type
    )
  end

  def deliver(result)
    allow(http_client).to receive(:post).and_return(result)
    operation.call(item: item)
  end

  describe '.call' do
    it 'delivers through the public operation api with default dependencies' do
      allow(Webhooks::HttpClient).to receive(:new).and_return(http_client)
      allow(http_client).to receive(:post).and_return(http_result(status: 200))

      described_class.call(item: item)

      expect(item.reload.status).to eq(ReplayItem::SUCCEEDED_STATUS)
      expect(http_client).to have_received(:post).once
    end

    it 'creates a replay delivery attempt and marks the original message succeeded' do
      deliver(http_result(status: 204))

      item.reload
      message.reload
      attempt = message.delivery_attempts.sole

      expect(item.status).to eq(ReplayItem::SUCCEEDED_STATUS)
      expect(item.completed_at).to eq(Time.current)
      expect(attempt.replay_item_id).to eq(item.id)
      expect(attempt).to be_replay
      expect(attempt.response_status).to eq(204)
      expect(message.status).to eq('succeeded')
      expect(message.terminal_at).to eq(Time.current)
    end

    it 'records a failed replay attempt and leaves the original message failed' do
      deliver(http_result(status: 503))

      item.reload
      message.reload
      attempt = message.delivery_attempts.sole

      expect(item.status).to eq(ReplayItem::FAILED_STATUS)
      expect(attempt).to be_replay
      expect(attempt.response_status).to eq(503)
      expect(message.status).to eq('failed')
    end

    it 'records transport errors without raising to the job' do
      deliver(http_result(error: 'read timeout', error_type: 'Net::ReadTimeout'))

      item.reload
      expect(item.status).to eq(ReplayItem::FAILED_STATUS)
      expect(item.error_type).to eq('Net::ReadTimeout')
      expect(item.delivery_attempt.error_type).to eq('Net::ReadTimeout')
    end

    it 'sends the event payload again rather than a historical attempt body' do
      sent = nil
      allow(http_client).to receive(:post) do |url:, headers:, body:, timeout:|
        sent = { url: url, headers: headers, body: body, timeout: timeout }
        http_result(status: 200)
      end

      operation.call(item: item)

      expect(sent[:url]).to eq(endpoint.url)
      expect(sent[:body]).to eq(Webhooks::AttemptEvidence.body_for(message))
    end

    it 'applies the circuit tracker to the replay result' do
      deliver(http_result(status: 503))

      expect(endpoint.reload.circuit_failure_count).to eq(1)
      expect(endpoint).to be_enabled
    end

    it 'resets the circuit failure count on a replay success' do
      endpoint.update!(circuit_failure_count: 2)

      deliver(http_result(status: 200))

      expect(endpoint.reload.circuit_failure_count).to eq(0)
    end

    it 'does not reserve delivery quota when the item is claimed' do
      account = project.effective_billing_owner
      UserUsagePeriod.reserve_deliveries!(user: account, quantity: 1, limit: 10)
      item.update!(quota_reserved_at: Time.current)

      deliver(http_result(status: 200))

      expect(account.deliveries_used_in_period).to eq(1)
    end
  end

  describe 'claim guards' do
    it 'does not deliver an item that is already terminal' do
      item.update!(status: ReplayItem::SUCCEEDED_STATUS, completed_at: Time.current)
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(http_client).not_to have_received(:post)
    end

    it 'does not deliver an item that is already delivering' do
      item.update!(status: ReplayItem::DELIVERING_STATUS, delivery_lease_expires_at: 1.minute.from_now)
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(http_client).not_to have_received(:post)
    end

    context 'when the endpoint circuit is open' do
      before { endpoint.update!(circuit_state: :circuit_open) }

      it 'holds the item without sending a request' do
        allow(http_client).to receive(:post)

        operation.call(item: item)

        expect(http_client).not_to have_received(:post)
        expect(item.reload.status).to eq(ReplayItem::HELD_STATUS)
        expect(item.hold_reason).to eq(ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
      end
    end

    context 'when the endpoint is archived' do
      before { endpoint.update!(archived_at: Time.current) }

      it 'skips the item' do
        operation.call(item: item)

        expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)
        expect(item.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_ARCHIVED)
      end
    end

    context 'when the endpoint is paused' do
      before { endpoint.update!(active: false) }

      it 'skips the item' do
        operation.call(item: item)

        expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)
        expect(item.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_PAUSED)
      end
    end

    context 'when the endpoint is disabled' do
      before { endpoint.update!(circuit_state: :disabled) }

      it 'skips the item' do
        operation.call(item: item)

        expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)
        expect(item.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_DISABLED)
      end
    end

    context 'when the endpoint has no current signing secret' do
      before { endpoint.endpoint_signing_secrets.update_all(retired_at: Time.current) }

      it 'fails the item without sending a request' do
        allow(http_client).to receive(:post)

        operation.call(item: item)

        expect(http_client).not_to have_received(:post)
        expect(item.reload.status).to eq(ReplayItem::FAILED_STATUS)
        expect(item.error_type).to eq(ReplayItem::MISSING_SECRET_ERROR_TYPE)
      end
    end

    context 'when the endpoint is at capacity' do
      before do
        Webhooks::DeliveryPolicy::MAX_ACTIVE_DELIVERIES_PER_ENDPOINT.times do
          create(:replay_item, replay_run: run, message: create(:message, project: project, endpoint: endpoint),
                               endpoint: endpoint, status: ReplayItem::DELIVERING_STATUS,
                               delivery_lease_expires_at: 1.minute.from_now)
        end
      end

      it 'reschedules the item without sending a request' do
        allow(http_client).to receive(:post)

        operation.call(item: item)

        expect(http_client).not_to have_received(:post)
        expect(item.reload.status).to eq(ReplayItem::QUEUED_STATUS)
        expect(ActiveJob::Base.queue_adapter.enqueued_jobs.last[:job]).to eq(Replays::DeliverJob)
      end
    end
  end
end
