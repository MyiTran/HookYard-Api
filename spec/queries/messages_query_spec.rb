require 'rails_helper'

describe MessagesQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project, event_type: 'order.created') }

  def results(**params)
    described_class.call(Message.all, **params).to_a
  end

  describe '.call' do
    describe 'ordering' do
      it 'returns the newest messages first by default' do
        older = create(:message, event: event, endpoint: endpoint, created_at: 2.hours.ago)
        newer = create(:message, event: create(:event, project: project), endpoint: endpoint, created_at: 1.hour.ago)

        expect(results.map(&:id)).to eq([newer.id, older.id])
      end

      it 'returns the oldest messages first with created_asc' do
        older = create(:message, event: event, endpoint: endpoint, created_at: 2.hours.ago)
        newer = create(:message, event: create(:event, project: project), endpoint: endpoint, created_at: 1.hour.ago)

        expect(results(order: 'created_asc').map(&:id)).to eq([older.id, newer.id])
      end

      it 'falls back to the default order for an unsupported value' do
        older = create(:message, event: event, endpoint: endpoint, created_at: 2.hours.ago)
        newer = create(:message, event: create(:event, project: project), endpoint: endpoint, created_at: 1.hour.ago)

        expect(results(order: 'created_at DESC; DROP TABLE messages').map(&:id)).to eq([newer.id, older.id])
      end
    end

    describe 'search' do
      let(:message) { create(:message, event: event, endpoint: endpoint) }

      it 'matches a partial message id' do
        message

        expect(results(q: message.id[0, 8])).to eq([message])
      end

      it 'matches a webhook id' do
        message

        expect(results(q: "msg_#{message.id}")).to eq([message])
      end

      it 'matches a delivery attempt request id without duplicating messages' do
        create(:delivery_attempt, message: message, attempt_number: 1, request_id: 'req_SUPPORT123')
        create(:delivery_attempt, message: message, attempt_number: 2, request_id: 'req_SUPPORT456')

        result = results(q: 'support123')

        expect(result.size).to eq(1)
        expect(result.first).to eq(message)
      end

      it 'returns every message when the search term is blank' do
        message
        other = create(:message, event: create(:event, project: project), endpoint: endpoint)

        expect(results(q: '  ').map(&:id)).to contain_exactly(message.id, other.id)
      end
    end

    describe 'filters' do
      it 'filters by project' do
        visible = create(:message, event: event, endpoint: endpoint)
        create(:message)

        expect(results(project_id: project.id)).to eq([visible])
      end

      it 'filters by endpoint' do
        other_endpoint = create(:endpoint, project: project)
        visible = create(:message, event: event, endpoint: endpoint)
        create(:message, event: create(:event, project: project), endpoint: other_endpoint)

        expect(results(endpoint_id: endpoint.id)).to eq([visible])
      end

      it 'filters by status' do
        succeeded = create(:message, event: event, endpoint: endpoint, status: :succeeded)
        create(:message, event: create(:event, project: project), endpoint: endpoint, status: :failed)

        expect(results(status: 'succeeded')).to eq([succeeded])
      end

      it 'filters by exact event type' do
        exact = create(:message, event: event, endpoint: endpoint)
        create(:message, event: create(:event, project: project, event_type: 'order.created.extra'), endpoint: endpoint)

        expect(results(event_type: 'order.created')).to eq([exact])
      end

      it 'filters by from and to' do
        old_message = create(:message, event: event, endpoint: endpoint, created_at: 3.days.ago)
        recent_message = create(:message, event: create(:event, project: project), endpoint: endpoint, created_at: 1.hour.ago)

        expect(results(from: 1.day.ago.iso8601).map(&:id)).to eq([recent_message.id])
        expect(results(to: 1.day.ago.iso8601).map(&:id)).to eq([old_message.id])
        expect(results(from: 4.days.ago.iso8601, to: Time.current.iso8601).map(&:id))
          .to contain_exactly(old_message.id, recent_message.id)
      end

      it 'combines multiple filters' do
        visible = create(:message, event: event, endpoint: endpoint, status: :succeeded)
        create(:message, event: create(:event, project: project, event_type: 'order.created'),
                         endpoint: endpoint, status: :failed)
        create(:message, event: create(:event, project: project, event_type: 'payment.failed'),
                         endpoint: endpoint, status: :succeeded)

        expect(results(project_id: project.id, endpoint_id: endpoint.id, status: 'succeeded', event_type: 'order.created'))
          .to eq([visible])
      end

      it 'ignores an unsupported status' do
        message = create(:message, event: event, endpoint: endpoint)

        expect(results(status: 'unknown')).to eq([message])
      end

      it 'ignores an invalid date instead of failing' do
        message = create(:message, event: event, endpoint: endpoint)

        expect(results(from: 'not-a-date', to: 'not-a-date')).to eq([message])
      end

      it 'ignores a malformed project id instead of failing' do
        message = create(:message, event: event, endpoint: endpoint)

        expect(results(project_id: 'not-a-uuid')).to eq([message])
      end
    end
  end
end
