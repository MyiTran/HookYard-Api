require 'rails_helper'

describe Messages::EnqueuePending, type: :operation do
  include ActiveJob::TestHelper

  describe '.call' do
    let(:event) { create(:event) }
    let(:now) { Time.current }
    let(:grace_seconds) { Constants::WEBHOOK_DELIVERY_ENQUEUE_GRACE_SECONDS }

    before { clear_enqueued_jobs }

    def create_message(status: :pending, age_seconds: 0)
      endpoint = create(:endpoint, project: event.project, event_types: [event.event_type])
      message = create(:message, event: event, endpoint: endpoint)
      message.update_columns(status: status.to_s, updated_at: now - age_seconds.seconds)
      message
    end

    it 'enqueues a pending message older than the grace period' do
      stale_message = create_message(age_seconds: grace_seconds + 1)

      expect { described_class.call(now: now) }
        .to have_enqueued_job(Messages::DeliverJob).with(stale_message.id)
    end

    it 'does not enqueue a pending message inside the grace period' do
      create_message(age_seconds: grace_seconds - 1)

      expect { described_class.call(now: now) }.not_to have_enqueued_job(Messages::DeliverJob)
    end

    it 'does not enqueue messages that are no longer pending' do
      %i[delivering succeeded failed].each { |status| create_message(status: status, age_seconds: grace_seconds + 1) }

      expect { described_class.call(now: now) }.not_to have_enqueued_job(Messages::DeliverJob)
    end

    it 'sends the stale message ids through the shared enqueue path' do
      stale_message = create_message(age_seconds: grace_seconds + 1)
      allow(Messages::EnqueueDelivery).to receive(:call)

      described_class.call(now: now)

      expect(Messages::EnqueueDelivery).to have_received(:call).with(message_ids: [stale_message.id])
    end
  end
end
