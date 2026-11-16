require 'rails_helper'

describe Events::FanOut, type: :operation do
  describe '.call' do
    let(:project) { create(:project) }
    let(:event) { create(:event, project: project, event_type: 'order.created') }

    it 'creates one message per endpoint subscribed to the exact event type' do
      endpoint = create(:endpoint, project: project, event_types: ['order.created'])

      message_ids = described_class.call(event: event)

      expect(message_ids.size).to eq(1)
      expect(event.messages.pluck(:endpoint_id)).to eq([endpoint.id])
    end

    it 'creates one message per endpoint subscribed to all events' do
      endpoint = create(:endpoint, project: project, event_types: ['*'])

      message_ids = described_class.call(event: event)

      expect(message_ids.size).to eq(1)
      expect(event.messages.pluck(:endpoint_id)).to eq([endpoint.id])
    end

    it 'excludes endpoints subscribed to other event types' do
      create(:endpoint, project: project, event_types: ['payment.failed'])

      expect(described_class.call(event: event)).to be_empty
      expect(event.messages.count).to eq(0)
    end

    it 'excludes inactive endpoints' do
      create(:endpoint, project: project, event_types: ['order.created'], active: false)

      expect(described_class.call(event: event)).to be_empty
    end

    it 'excludes archived endpoints' do
      create(:endpoint, project: project, event_types: ['order.created'], archived_at: Time.current)

      expect(described_class.call(event: event)).to be_empty
    end

    it 'excludes endpoints from another project' do
      create(:endpoint, event_types: ['order.created'])

      expect(described_class.call(event: event)).to be_empty
    end

    it 'creates exactly one message per eligible endpoint' do
      create_list(:endpoint, 12, project: project, event_types: ['order.created'])

      expect(described_class.call(event: event).size).to eq(12)
      expect(event.messages.count).to eq(12)
    end

    it 'does not create duplicates when the event is fanned out again' do
      create_list(:endpoint, 3, project: project, event_types: ['order.created'])
      described_class.call(event: event)

      expect(described_class.call(event: event)).to be_empty
      expect(event.messages.count).to eq(3)
    end
  end
end
