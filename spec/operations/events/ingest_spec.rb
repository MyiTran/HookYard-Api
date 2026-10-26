require 'rails_helper'

describe Events::Ingest, type: :operation do
  include ActiveJob::TestHelper

  describe '.call' do
    let(:project) { create(:project) }
    let(:attributes) do
      { event_type: 'order.created', payload: { 'order_id' => 'ord_1' }, idempotency_key: 'order-1' }
    end

    before { clear_enqueued_jobs }

    it 'creates exactly one event for the project' do
      result = described_class.call(project: project, attributes: attributes)

      expect(Event.where(project: project).count).to eq(1)
      expect(result.created).to be(true)
      expect(result.event.event_type).to eq('order.created')
      expect(result.event.payload).to eq('order_id' => 'ord_1')
    end

    it 'creates exactly one message per matching endpoint' do
      create_list(:endpoint, 12, project: project, event_types: ['order.created'])

      result = described_class.call(project: project, attributes: attributes)

      expect(Message.where(event_id: result.event.id).count).to eq(12)
      expect(result.messages_count).to eq(12)
    end

    it 'enqueues one delivery job per newly created message' do
      create_list(:endpoint, 2, project: project, event_types: ['order.created'])

      expect { described_class.call(project: project, attributes: attributes) }
        .to have_enqueued_job(Messages::DeliverJob).exactly(2).times
    end

    context 'when the same request is repeated' do
      it 'returns the existing event without creating new events or messages' do
        create_list(:endpoint, 2, project: project, event_types: ['order.created'])
        first = described_class.call(project: project, attributes: attributes)

        expect { @duplicate = described_class.call(project: project, attributes: attributes) }
          .not_to change { [Event.count, Message.count] }

        expect(@duplicate.created).to be(false)
        expect(@duplicate.event).to eq(first.event)
        expect(@duplicate.messages_count).to eq(0)
        expect(Event.where(project: project).count).to eq(1)
        expect(Message.where(event_id: first.event.id).count).to eq(2)
      end
    end

    context 'when the same idempotency key is used with different content' do
      it 'raises an unprocessable entity error' do
        described_class.call(project: project, attributes: attributes)

        expect do
          described_class.call(project: project, attributes: attributes.merge(payload: { 'order_id' => 'ord_2' }))
        end.to raise_error(ApiError::UnprocessableEntityError)

        expect(Event.where(project: project).count).to eq(1)
      end
    end

    context 'when the delivery enqueue fails after the event is committed' do
      before do
        create(:endpoint, project: project, event_types: ['order.created'])
        allow(Messages::DeliverJob).to receive(:perform_later).and_raise(RuntimeError, 'redis unavailable')
        allow(Rails.logger).to receive(:error)
      end

      it 'keeps the event and its message committed' do
        result = described_class.call(project: project, attributes: attributes)

        expect(Event.where(project: project).count).to eq(1)
        expect(Message.where(event_id: result.event.id).pluck(:status)).to eq(['pending'])
      end

      it 'logs the enqueue failure instead of raising' do
        expect { described_class.call(project: project, attributes: attributes) }.not_to raise_error

        expect(Rails.logger).to have_received(:error).with(/Webhook delivery enqueue failed/)
      end
    end

    context 'when the same idempotency key is repeated after an enqueue failure' do
      before do
        create(:endpoint, project: project, event_types: ['order.created'])
        allow(Messages::DeliverJob).to receive(:perform_later).and_raise(RuntimeError, 'redis unavailable')
        allow(Rails.logger).to receive(:error)
      end

      it 'does not create another event or message' do
        described_class.call(project: project, attributes: attributes)

        expect { described_class.call(project: project, attributes: attributes) }
          .not_to change { [Event.count, Message.count] }
      end

      it 're-sends the pending message through the shared enqueue path' do
        first = described_class.call(project: project, attributes: attributes)
        allow(Messages::DeliverJob).to receive(:perform_later).and_call_original
        allow(Messages::EnqueueDelivery).to receive(:call).and_call_original

        expect { described_class.call(project: project, attributes: attributes) }
          .to have_enqueued_job(Messages::DeliverJob).with(first.message_ids.first)

        expect(Messages::EnqueueDelivery).to have_received(:call).with(message_ids: first.message_ids)
      end

      it 'keeps the duplicate response unchanged' do
        first = described_class.call(project: project, attributes: attributes)

        duplicate = described_class.call(project: project, attributes: attributes)

        expect(duplicate.created).to be(false)
        expect(duplicate.event).to eq(first.event)
        expect(duplicate.messages_count).to eq(0)
      end
    end

    context 'when no endpoint subscribes to the event type' do
      it 'accepts the event without creating messages' do
        create(:endpoint, project: project, event_types: ['payment.failed'])

        result = described_class.call(project: project, attributes: attributes)

        expect(result.created).to be(true)
        expect(result.messages_count).to eq(0)
      end
    end
  end

  describe '.call under concurrent duplicate requests' do
    self.use_transactional_tests = false

    after { Project.delete_all }

    it 'creates exactly one event and one message per endpoint' do
      project = create(:project)
      create_list(:endpoint, 3, project: project, event_types: ['order.created'])
      attributes = { event_type: 'order.created', payload: { 'order_id' => 'ord_1' }, idempotency_key: 'concurrent-1' }
      project_id = project.id
      barrier = Queue.new

      threads = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.pop
            described_class.call(project: Project.find(project_id), attributes: attributes)
          end
        end
      end
      2.times { barrier << true }
      results = threads.map(&:value)

      expect(Event.where(project_id: project_id).count).to eq(1)
      expect(Message.where(event_id: Event.where(project_id: project_id).select(:id)).count).to eq(3)
      expect(results.count(&:created)).to eq(1)
    end
  end
end
