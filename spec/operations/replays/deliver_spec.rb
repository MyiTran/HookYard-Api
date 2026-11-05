require 'rails_helper'

describe Replays::Deliver, type: :operation do
  let(:project) { create(:project) }
  let(:actor) { create(:user) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint, status: :failed) }
  let(:run) { create(:replay_run, project: project, actor: actor) }
  let(:item) { create(:replay_item, replay_run: run, message: message, endpoint: endpoint) }
  let(:http_client) { double('http_client') }
  let(:operation) { described_class.new(http_client: http_client, signer: Webhooks::Signer) }

  before { travel_to(Time.zone.local(2026, 1, 1, 12, 0, 0)) }

  def http_result(status: nil, headers: {}, body: nil, error: nil, error_type: nil)
    Webhooks::HttpClient::Result.new(
      status: status,
      headers: headers,
      body: status.nil? ? nil : body,
      duration_ms: 12,
      error: error,
      error_type: error_type
    )
  end

  def deliver(result)
    allow(http_client).to receive(:post).and_return(result)
    operation.call(item: item)
  end

  describe 'successful replay' do
    before do
      message.update!(attempt_count: 8, terminal_at: Time.zone.local(2026, 1, 1, 10, 0, 0))
      create_list(:delivery_attempt, 8, message: message)
    end

    it 'records a replay attempt that continues the attempt numbering' do
      deliver(http_result(status: 204))

      attempt = item.reload.delivery_attempt
      expect(item.status).to eq(ReplayItem::SUCCEEDED_STATUS)
      expect(item.completed_at).to eq(Time.current)
      expect(item.started_at).to eq(Time.current)
      expect(attempt.attempt_number).to eq(9)
      expect(attempt).to be_replay
      expect(attempt.response_status).to eq(204)
      expect(attempt.replay_item_id).to eq(item.id)
    end

    it 'resolves the failed message into a succeeded one at the replay completion time' do
      deliver(http_result(status: 200))

      message.reload
      expect(message.status).to eq('succeeded')
      expect(message.terminal_at).to eq(Time.current)
      expect(message.next_retry_at).to be_nil
      expect(message.delivery_lease_expires_at).to be_nil
      expect(message.held_at).to be_nil
      expect(message.delivery_state).to eq(Message::DELIVERY_STATE_TERMINAL)
    end

    it 'keeps the automatic attempt history and its retry usage' do
      deliver(http_result(status: 200))

      attempts = message.reload.delivery_attempts
      expect(message.attempt_count).to eq(8)
      expect(attempts.map(&:attempt_number)).to eq((1..9).to_a)
      expect(attempts.first(8).map(&:replay_item_id)).to all(be_nil)
      expect(attempts.last.replay_item_id).to eq(item.id)
    end

    it 'does not release an endpoint queue slot a second time' do
      endpoint.update!(queued_message_count: 3)

      deliver(http_result(status: 200))

      expect(endpoint.reload.queued_message_count).to eq(3)
      expect(message.reload.queued_at).to be_nil
    end

    it 'does not schedule another automatic delivery' do
      deliver(http_result(status: 204))

      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
    end

    it 'does not charge the delivery metering' do
      expect { deliver(http_result(status: 204)) }
        .not_to change { project.billing_owner.deliveries_used_in_period }
    end

    it 'does not create events or messages' do
      expect { deliver(http_result(status: 204)) }
        .not_to change { [Event.count, Message.count] }
    end

    it 'makes the message no longer replayable while keeping the replay audit outcome' do
      deliver(http_result(status: 200))

      summary = Replays::Eligibility.summary_for(message.reload)
      expect(summary).to include(
        allowed: false,
        blocked_reason: Replays::Eligibility::REASON_NOT_FAILED,
        active: false
      )
      expect(summary[:last_outcome]).to include(id: item.id, status: ReplayItem::SUCCEEDED_STATUS)
    end

    it 'signs the replayed event payload with the current secret' do
      captured = nil
      allow(http_client).to receive(:post) do |attributes|
        captured = attributes
        http_result(status: 200)
      end

      operation.call(item: item)

      payload = Oj.load(captured[:body])
      expect(payload['id']).to eq(event.id)
      expect(payload['type']).to eq(event.event_type)
      expect(captured[:url]).to eq(endpoint.url)
      expect(captured[:timeout]).to eq(Webhooks::DeliveryPolicy.timeout_seconds_for(project))
      expect(captured[:headers]['webhook-id']).to eq(message.webhook_id)
      expect(captured[:headers]['webhook-request-id']).to start_with('req_')
      expect(
        Webhooks::Signer.verify(
          secret: endpoint.current_signing_secret.secret,
          webhook_id: captured[:headers]['webhook-id'],
          timestamp: captured[:headers]['webhook-timestamp'],
          body: captured[:body],
          signature: captured[:headers]['webhook-signature']
        )['id']
      ).to eq(event.id)
    end

    it 'resets the circuit failure count after a successful replay' do
      endpoint.update!(circuit_failure_count: 2)

      deliver(http_result(status: 200))

      expect(endpoint.reload.circuit_failure_count).to eq(0)
    end
  end

  describe 'failed replay' do
    it 'marks the item failed with the recorded attempt evidence' do
      deliver(http_result(status: 500, body: 'boom'))

      expect(item.reload.status).to eq(ReplayItem::FAILED_STATUS)
      expect(item.completed_at).to eq(Time.current)
      expect(item.delivery_attempt.response_status).to eq(500)
      expect(message.reload.status).to eq('failed')
    end

    it 'stores transport errors on the replay item' do
      deliver(http_result(error: 'execution expired', error_type: 'Net::ReadTimeout'))

      expect(item.reload.error_type).to eq('Net::ReadTimeout')
      expect(item.delivery_attempt.error_message).to eq('execution expired')
    end

    it 'leaves the message failed, replayable and without a new retry schedule' do
      terminal_at = Time.zone.local(2026, 1, 1, 10, 0, 0)
      message.update!(attempt_count: 8, terminal_at: terminal_at)
      create_list(:delivery_attempt, 8, message: message)

      deliver(http_result(status: 500, body: 'boom'))

      message.reload
      expect(message.status).to eq('failed')
      expect(message.attempt_count).to eq(8)
      expect(message.terminal_at).to eq(terminal_at)
      expect(message.next_retry_at).to be_nil
      expect(Replays::Eligibility.summary_for(message)[:allowed]).to be(true)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
    end

    it 'opens the circuit after the fifth counted replay failure without retrying' do
      messages = create_list(:message, 5, project: project, endpoint: endpoint, status: :failed)
      items = messages.map { |target| create(:replay_item, replay_run: run, message: target, endpoint: endpoint) }
      allow(http_client).to receive(:post).and_return(http_result(status: 503))

      items.each { |target| operation.call(item: target) }

      expect(endpoint.reload).to be_circuit_open
      expect(items.map { |target| target.reload.status }.uniq).to eq([ReplayItem::FAILED_STATUS])
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs).to be_empty
    end
  end

  describe 'endpoint state at execution time' do
    it 'holds the item while the circuit is open instead of sending it' do
      endpoint.update!(circuit_state: :circuit_open)
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(item.reload.status).to eq(ReplayItem::HELD_STATUS)
      expect(item.hold_reason).to eq(ReplayItem::HOLD_REASON_CIRCUIT_OPEN)
      expect(http_client).not_to have_received(:post)
    end

    it 'skips the item when the endpoint was archived after confirmation' do
      endpoint.update!(archived_at: Time.current)
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)
      expect(item.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_ARCHIVED)
      expect(http_client).not_to have_received(:post)
    end

    it 'skips the item when the endpoint was disabled after confirmation' do
      endpoint.update!(circuit_state: :disabled)
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(item.reload.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_DISABLED)
      expect(http_client).not_to have_received(:post)
    end

    it 'skips the item when the endpoint was paused after confirmation' do
      endpoint.update!(active: false)
      allow(http_client).to receive(:post)

      expect { operation.call(item: item) }
        .not_to change { project.billing_owner.deliveries_used_in_period }

      expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)
      expect(item.skip_reason).to eq(ReplayItem::SKIP_REASON_ENDPOINT_PAUSED)
      expect(item.completed_at).to be_present
      expect(http_client).not_to have_received(:post)
      expect(item.delivery_attempt).to be_nil
      expect(message.reload.status).to eq('failed')
      expect(message.next_retry_at).to be_nil
    end

    it 'defers the item while the endpoint is at the concurrency limit' do
      Webhooks::DeliveryPolicy.jitter_source = -> { 0 }
      create_list(:message, 3, project: project, endpoint: endpoint).each do |active|
        active.update_columns(status: 'delivering', delivery_lease_expires_at: 30.seconds.from_now)
      end
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(item.reload.status).to eq(ReplayItem::QUEUED_STATUS)
      expect(http_client).not_to have_received(:post)
      job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
      expect(job[:job]).to eq(Replays::DeliverJob)
      expect(job[:args]).to eq([item.id])
      expect(job[:at]).to be_within(0.001).of(
        (Time.current + Webhooks::DeliveryPolicy::CAPACITY_RETRY_DELAY).to_f
      )
    end

    it 'fails the item when the endpoint has no signing secret' do
      endpoint.endpoint_signing_secrets.destroy_all
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(item.reload.status).to eq(ReplayItem::FAILED_STATUS)
      expect(item.error_type).to eq(ReplayItem::MISSING_SECRET_ERROR_TYPE)
      expect(http_client).not_to have_received(:post)
    end
  end

  describe 'resuming a paused endpoint' do
    it 'does not resurrect previously skipped replays and allows a new replay to proceed' do
      endpoint.update!(active: false)
      allow(http_client).to receive(:post).and_return(http_result(status: 200))

      operation.call(item: item)
      expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)

      endpoint.update!(active: true)
      Replays::ReleaseHeld.call(endpoint: endpoint)
      expect(item.reload.status).to eq(ReplayItem::SKIPPED_STATUS)

      new_run = Replays::Create.call(message: message.reload, actor: actor)
      new_item = new_run.replay_items.first
      expect(new_item.status).to eq(ReplayItem::QUEUED_STATUS)

      operation.call(item: new_item)
      expect(new_item.reload.status).to eq(ReplayItem::SUCCEEDED_STATUS)
      expect(message.reload.status).to eq('succeeded')
    end
  end

  describe 'duplicate execution' do
    it 'does not resend an item that already finished' do
      item.update!(status: ReplayItem::SUCCEEDED_STATUS, completed_at: Time.current)
      allow(http_client).to receive(:post)

      operation.call(item: item)

      expect(http_client).not_to have_received(:post)
      expect(message.delivery_attempts.count).to eq(0)
    end
  end
end
