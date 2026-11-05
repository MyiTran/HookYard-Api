require 'rails_helper'

describe MessagesQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project, event_type: 'order.created') }

  def results(**params)
    described_class.call(Message.all, **params).to_a
  end

  def new_message(**attributes)
    create(:message, project: project, endpoint: endpoint, **attributes)
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

  describe 'delivery state filter' do
    let!(:open_circuit_message) { new_message.tap { |message| message.hold!(reason: 'endpoint_circuit_open') } }
    let!(:disabled_endpoint_message) { new_message.tap { |message| message.hold!(reason: 'endpoint_disabled') } }
    let!(:queued_message) { new_message }
    let!(:scheduled_retry_message) { new_message(next_retry_at: 1.minute.from_now) }
    let!(:delivering_message) { new_message.tap { |message| message.update_columns(status: 'delivering') } }
    let!(:succeeded_message) { new_message(status: :succeeded, terminal_at: Time.current) }
    let!(:failed_message) { new_message(status: :failed, terminal_at: Time.current) }

    context 'when filtering held messages' do
      it 'returns messages held by an open circuit and by a disabled endpoint' do
        expect(results(delivery_state: 'held_by_circuit')).to contain_exactly(open_circuit_message, disabled_endpoint_message)
      end

      it 'excludes queued, retry-scheduled, delivering and terminal messages' do
        held_ids = results(delivery_state: 'held_by_circuit').map(&:id)

        expect(held_ids).not_to include(
          queued_message.id,
          scheduled_retry_message.id,
          delivering_message.id,
          succeeded_message.id,
          failed_message.id
        )
      end

      it 'excludes pending messages of a paused endpoint that are not held' do
        paused_endpoint = create(:endpoint, project: project, active: false)
        paused_message = create(:message, project: project, endpoint: paused_endpoint)

        expect(results(delivery_state: 'held_by_circuit')).not_to include(paused_message)
      end

      it 'excludes a message that already completed a successful probe' do
        probe = new_message
        probe.hold!(reason: 'endpoint_circuit_open')
        probe.mark_delivering!(lease_expires_at: 1.minute.from_now, attempt_count: 1)
        probe.mark_succeeded!

        expect(results(delivery_state: 'held_by_circuit')).to contain_exactly(open_circuit_message, disabled_endpoint_message)
      end

      it 'combines with the project and endpoint filters' do
        other_endpoint = create(:endpoint, project: project)
        other_message = create(:message, project: project, endpoint: other_endpoint)
        other_message.hold!(reason: 'endpoint_circuit_open')
        other_project_message = create(:message)
        other_project_message.hold!(reason: 'endpoint_circuit_open')

        expect(results(delivery_state: 'held_by_circuit', project_id: project.id)).to contain_exactly(
          open_circuit_message, disabled_endpoint_message, other_message
        )
        expect(results(delivery_state: 'held_by_circuit', endpoint_id: other_endpoint.id)).to contain_exactly(other_message)
      end
    end

    context 'when the delivery state is unknown' do
      it 'raises an unprocessable entity error' do
        expect { results(delivery_state: 'closed') }.to raise_error(ApiError::UnprocessableEntityError)
      end
    end

    context 'when the delivery state is blank' do
      it 'returns every message' do
        expect(results(delivery_state: '')).to contain_exactly(
          open_circuit_message, disabled_endpoint_message, queued_message,
          scheduled_retry_message, delivering_message, succeeded_message, failed_message
        )
      end
    end
  end
  end
end
