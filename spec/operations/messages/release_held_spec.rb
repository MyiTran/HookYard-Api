require 'rails_helper'

describe Messages::ReleaseHeld, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }

  before do
    endpoint.update!(
      circuit_state: 'circuit_open',
      circuit_failure_count: 5,
      circuit_opened_at: Time.current,
      circuit_disable_at: Time.current + 5.days
    )
  end

  def held_message(created_at: Time.current)
    queued_message(created_at: created_at).tap do |message|
      message.update_columns(held_at: created_at, hold_reason: 'endpoint_circuit_open')
    end
  end

  def queued_message(created_at: Time.current)
    create(:message, project: project, endpoint: endpoint).tap do |message|
      message.update_columns(queued_at: created_at, created_at: created_at)
      Endpoint.where(id: endpoint.id).update_all('queued_message_count = queued_message_count + 1')
    end
  end

  def enqueued_message_ids
    ActiveJob::Base.queue_adapter.enqueued_jobs
                       .select { |job| job[:job] == Messages::DeliverJob }
                       .map { |job| job[:args].first }
  end

  def delivery_operation
    Messages::Deliver.new(http_client: double(post: http_result(status: 200)), signer: Webhooks::Signer)
  end

  def http_result(status:)
    Webhooks::HttpClient::Result.new(
      status: status, headers: {}, body: 'ok', duration_ms: 5, error: nil, error_type: nil
    )
  end

  describe '.call' do
    it 'releases every held message and enqueues its delivery' do
      first = held_message
      second = held_message
      delivered = create(:message, project: project, endpoint: endpoint, status: :succeeded)

      described_class.call(endpoint: endpoint)

      expect(first.reload.held_at).to be_nil
      expect(first.hold_reason).to be_nil
      expect(second.reload.held_at).to be_nil
      expect(delivered.reload.status).to eq('succeeded')
      expect(enqueued_message_ids).to contain_exactly(first.id, second.id)
    end

    it 'releases a pending message that never carried a hold and clears its stale retry' do
      stranded = queued_message
      stranded.update_columns(next_retry_at: 5.hours.from_now)

      described_class.call(endpoint: endpoint)

      stranded.reload
      expect(stranded.status).to eq('pending')
      expect(stranded.held_at).to be_nil
      expect(stranded.next_retry_at).to be_nil
      expect(enqueued_message_ids).to contain_exactly(stranded.id)
    end

    it 'leaves no pending message behind after the release' do
      3.times { held_message }
      queued_message

      described_class.call(endpoint: endpoint)

      expect(endpoint.messages.pending.count).to eq(4)
      expect(endpoint.messages.held).to be_empty
      expect(enqueued_message_ids).to match_array(endpoint.messages.pluck(:id))
    end

    it 'never replays a terminal failed message' do
      failed = queued_message
      failed.update_columns(status: 'failed', terminal_at: Time.current, next_retry_at: Time.current)

      described_class.call(endpoint: endpoint)

      expect(failed.reload.status).to eq('failed')
      expect(failed.held_at).to be_nil
      expect(enqueued_message_ids).to be_empty
    end

    it 'leaves a message with an active delivery lease untouched' do
      in_flight = queued_message
      in_flight.update_columns(
        status: 'delivering',
        attempt_count: 1,
        delivery_lease_expires_at: 30.seconds.from_now
      )

      described_class.call(endpoint: endpoint)

      expect(in_flight.reload.status).to eq('delivering')
      expect(in_flight.delivery_lease_expires_at).to be_present
      expect(enqueued_message_ids).to be_empty
    end

    it 'releases messages in bounded batches' do
      stub_const('Webhooks::CircuitPolicy::RELEASE_BATCH_SIZE', 2)
      held_message(created_at: 3.minutes.ago)
      held_message(created_at: 2.minutes.ago)
      held_message(created_at: 1.minute.ago)
      allow(Messages::EnqueueDelivery).to receive(:call).and_call_original

      described_class.call(endpoint: endpoint)

      expect(Messages::EnqueueDelivery).to have_received(:call).twice
      expect(endpoint.messages.held).to be_empty
    end

    it 'leaves messages of other endpoints untouched' do
      other_endpoint = create(:endpoint, project: project)
      other = create(:message, project: project, endpoint: other_endpoint)
      other.update_columns(held_at: Time.current, hold_reason: 'endpoint_circuit_open')

      described_class.call(endpoint: endpoint)

      expect(other.reload.held_at).to be_present
      expect(enqueued_message_ids).to be_empty
    end

    it 'skips the messages listed as excluded' do
      excluded = held_message
      released = held_message(created_at: 1.minute.from_now)

      described_class.call(endpoint: endpoint, except_ids: [excluded.id])

      expect(excluded.reload.held_at).to be_present
      expect(excluded.hold_reason).to eq('endpoint_circuit_open')
      expect(released.reload.held_at).to be_nil
      expect(enqueued_message_ids).to contain_exactly(released.id)
    end
  end

  describe 'queue counter after recovery' do
    it 'decrements the durable counter exactly once per successful released delivery' do
      endpoint.update!(circuit_state: 'enabled')
      messages = Array.new(3) { held_message }

      described_class.call(endpoint: endpoint)

      expect(endpoint.reload.queued_message_count).to eq(3)

      messages.each_with_index do |message, index|
        delivery_operation.call(message: message)

        expect(message.reload).to be_succeeded
        expect(endpoint.reload.queued_message_count).to eq(2 - index)
      end

      expect(endpoint.reload.queued_message_count).to eq(0)
      expect(endpoint.messages.where.not(queued_at: nil)).to be_empty
    end

    it 'reaches zero after the whole released backlog drains' do
      endpoint.update!(circuit_state: 'enabled')
      messages = Array.new(5) { held_message }

      described_class.call(endpoint: endpoint)
      messages.each { |message| delivery_operation.call(message: message) }

      expect(endpoint.reload.queued_message_count).to eq(0)
      expect(endpoint.queue_state).to eq('ok')
    end
  end

  describe 'draining a recovered backlog' do
    it 'keeps at most three deliveries in flight and parks the rest' do
      endpoint.update!(circuit_state: 'enabled')
      messages = Array.new(4) { held_message }
      described_class.call(endpoint: endpoint)
      remaining = messages.drop(1)
      client = double('http_client')

      allow(client).to receive(:post) do
        next_message = remaining.shift
        Messages::Deliver.new(http_client: client, signer: Webhooks::Signer).call(message: next_message) if next_message
        http_result(status: 200)
      end

      Messages::Deliver.new(http_client: client, signer: Webhooks::Signer).call(message: messages.first)

      expect(messages.first(3).map { |message| message.reload.status }).to all(eq('succeeded'))

      parked = messages.last.reload
      expect(parked.status).to eq('pending')
      expect(parked.attempt_count).to eq(0)
      expect(parked.next_retry_at).to be_present
      expect(endpoint.reload.queued_message_count).to eq(1)
    end
  end
end
