require 'rails_helper'

describe Events::Ingest, type: :operation do
  let(:project) { create(:project) }
  let!(:endpoint) { create(:endpoint, project: project) }
  let(:attributes) do
    {
      event_type: 'order.created',
      payload: { 'order_id' => SecureRandom.uuid },
      idempotency_key: SecureRandom.uuid
    }
  end

  before { endpoint.update!(event_types: [Endpoint::WILDCARD_EVENT_TYPE]) }

  describe '.call' do
    it 'persists the event with its messages and enqueues delivery' do
      expect { @result = described_class.call(project: project, attributes: attributes) }
        .to have_enqueued_job(Messages::DeliverJob)

      expect(@result.created).to be(true)
      expect(@result.event).to be_persisted
      expect(@result.messages_count).to eq(1)
    end

    it 'keeps the committed event and messages waiting when enqueueing fails' do
      allow(Messages::DeliverJob).to receive(:perform_later).and_raise(StandardError, 'redis unavailable')
      allow(Rails.logger).to receive(:error).and_call_original

      result = described_class.call(project: project, attributes: attributes)

      expect(result.event.reload).to be_persisted
      expect(result.event.messages.pending.count).to eq(1)
      expect(Rails.logger).to have_received(:error).with(/enqueue failed for message/)
    end

    it 'increments the endpoint queue count for every created message' do
      described_class.call(project: project, attributes: attributes)

      expect(endpoint.reload.queued_message_count).to eq(1)
    end

    it 'does not count a duplicate event twice' do
      described_class.call(project: project, attributes: attributes)
      described_class.call(project: project, attributes: attributes)

      expect(endpoint.reload.queued_message_count).to eq(1)
      expect(project.events.count).to eq(1)
    end

    it 'keeps queued messages available to a paused endpoint only through manual action' do
      endpoint.update!(active: false)

      result = described_class.call(project: project, attributes: attributes)

      expect(result.messages_count).to eq(0)
      expect(endpoint.reload.queued_message_count).to eq(0)
      expect(endpoint).to be_enabled
    end

    context 'when the endpoint circuit is open' do
      before do
        endpoint.update!(
          circuit_state: 'circuit_open',
          circuit_failure_count: 5,
          circuit_opened_at: Time.current,
          circuit_next_probe_at: Time.current
        )
      end

      it 'accepts the message but holds it without enqueueing delivery' do
        result = nil

        expect { result = described_class.call(project: project, attributes: attributes) }
          .not_to have_enqueued_job(Messages::DeliverJob)

        message = result.event.messages.first
        expect(result.messages_count).to eq(1)
        expect(message).to be_held
        expect(message.hold_reason).to eq('endpoint_circuit_open')
        expect(endpoint.reload.queued_message_count).to eq(1)
      end
    end

    context 'when the endpoint circuit is disabled' do
      before { endpoint.update!(circuit_state: 'disabled', circuit_failure_count: 5) }

      it 'accepts the message but holds it for the disabled endpoint' do
        expect { described_class.call(project: project, attributes: attributes) }
          .not_to have_enqueued_job(Messages::DeliverJob)

        message = project.events.last.messages.first
        expect(message).to be_held
        expect(message.hold_reason).to eq('endpoint_disabled')
      end
    end

    context 'when an eligible endpoint queue is full' do
      before { endpoint.update_columns(queued_message_count: Webhooks::CircuitPolicy::QUEUE_CAPACITY) }

      it 'rejects the whole event atomically and records the rejection' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::QueueCapacityExceededError)

        expect(project.events.count).to eq(0)
        expect(Message.where(endpoint_id: endpoint.id).count).to eq(0)
        rejection = IngestRejection.sole
        expect(rejection.project).to eq(project)
        expect(rejection.endpoint).to eq(endpoint)
        expect(rejection.reason).to eq('queue_capacity_exceeded')
        expect(rejection.event_type).to eq('order.created')
        expect(rejection.idempotency_key).to eq(attributes[:idempotency_key])
        expect(rejection.payload).to eq(attributes[:payload])
      end

      it 'does not reserve the idempotency key so a later retry can succeed' do
        expect { described_class.call(project: project, attributes: attributes) }
          .to raise_error(ApiError::QueueCapacityExceededError)

        endpoint.update_columns(queued_message_count: 0)
        result = described_class.call(project: project, attributes: attributes)

        expect(result.created).to be(true)
        expect(result.messages_count).to eq(1)
        expect(project.events.count).to eq(1)
      end
    end
  end

  describe 'concurrent fan-out' do
    self.use_transactional_tests = false

    after { project.destroy! }

    it 'keeps the endpoint queue counter aligned with the created messages' do
      start = Queue.new

      threads = Array.new(3) do |index|
        Thread.new do
          start.pop
          ActiveRecord::Base.connection_pool.with_connection do
            described_class.call(
              project: Project.find(project.id),
              attributes: {
                event_type: 'order.created',
                payload: { 'index' => index },
                idempotency_key: "concurrent-#{index}"
              }
            )
          end
        end
      end

      3.times { start.push(true) }
      threads.each(&:join)

      expect(endpoint.reload.queued_message_count).to eq(3)
      expect(endpoint.messages.pending.count).to eq(3)
    end
  end
end
