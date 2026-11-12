require 'rails_helper'

describe MessagesQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:scope) { Message.all }
  let!(:open_circuit_message) { new_message.tap { |message| message.hold!(reason: 'endpoint_circuit_open') } }
  let!(:disabled_endpoint_message) { new_message.tap { |message| message.hold!(reason: 'endpoint_disabled') } }
  let!(:queued_message) { new_message }
  let!(:scheduled_retry_message) { new_message(next_retry_at: 1.minute.from_now) }
  let!(:delivering_message) { new_message.tap { |message| message.update_columns(status: 'delivering') } }
  let!(:succeeded_message) { new_message(status: :succeeded, terminal_at: Time.current) }
  let!(:failed_message) { new_message(status: :failed, terminal_at: Time.current) }

  def run(**params)
    described_class.call(scope, **params)
  end

  def new_message(**attributes)
    create(:message, project: project, endpoint: endpoint, **attributes)
  end

  describe 'delivery state filter' do
    context 'when filtering held messages' do
      it 'returns messages held by an open circuit and by a disabled endpoint' do
        expect(run(delivery_state: 'held_by_circuit')).to contain_exactly(open_circuit_message, disabled_endpoint_message)
      end

      it 'excludes queued, retry-scheduled, delivering and terminal messages' do
        held_ids = run(delivery_state: 'held_by_circuit').ids

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

        expect(run(delivery_state: 'held_by_circuit')).not_to include(paused_message)
      end

      it 'excludes a message that already completed a successful probe' do
        probe = new_message
        probe.hold!(reason: 'endpoint_circuit_open')
        probe.mark_delivering!(lease_expires_at: 1.minute.from_now, attempt_count: 1)
        probe.mark_succeeded!

        expect(run(delivery_state: 'held_by_circuit')).to contain_exactly(open_circuit_message, disabled_endpoint_message)
      end

      it 'combines with the project and endpoint filters' do
        other_endpoint = create(:endpoint, project: project)
        other_message = create(:message, project: project, endpoint: other_endpoint)
        other_message.hold!(reason: 'endpoint_circuit_open')
        other_project_message = create(:message)
        other_project_message.hold!(reason: 'endpoint_circuit_open')

        expect(run(delivery_state: 'held_by_circuit', project_id: project.id)).to contain_exactly(
          open_circuit_message, disabled_endpoint_message, other_message
        )
        expect(run(delivery_state: 'held_by_circuit', endpoint_id: other_endpoint.id)).to contain_exactly(other_message)
      end
    end

    context 'when the delivery state is unknown' do
      it 'raises an unprocessable entity error' do
        expect { run(delivery_state: 'closed') }.to raise_error(ApiError::UnprocessableEntityError)
      end
    end

    context 'when the delivery state is blank' do
      it 'returns every message' do
        expect(run(delivery_state: '')).to contain_exactly(
          open_circuit_message, disabled_endpoint_message, queued_message,
          scheduled_retry_message, delivering_message, succeeded_message, failed_message
        )
      end
    end
  end

  describe 'failure category filter' do
    it 'filters messages by the failure category of their latest attempt' do
      create(:delivery_attempt, message: failed_message, attempt_number: 1, error_type: 'Net::ReadTimeout')

      expect(run(failure_category: Webhooks::FailureCategory::TIMEOUT)).to contain_exactly(failed_message)
    end

    it 'classifies the latest attempt only' do
      retried_message = new_message
      create(:delivery_attempt, message: retried_message, attempt_number: 1, error_type: 'Net::ReadTimeout')
      create(:delivery_attempt, message: retried_message, attempt_number: 2, response_status: 500)

      expect(run(failure_category: Webhooks::FailureCategory::HTTP_ERROR)).to contain_exactly(retried_message)
      expect(run(failure_category: Webhooks::FailureCategory::TIMEOUT)).to be_empty
    end

    it 'never classifies a successful delivery as a failure' do
      create(:delivery_attempt, message: succeeded_message, attempt_number: 1, response_status: 200)

      expect(run(failure_category: Webhooks::FailureCategory::HTTP_ERROR)).to be_empty
    end

    it 'ignores an unknown category' do
      expect(run(failure_category: 'made_up').count(:all)).to eq(7)
    end
  end

  describe 'exact identifier search' do
    let!(:attempt) { create(:delivery_attempt, message: queued_message, request_id: 'req_exact-123') }

    it 'finds a message by its exact id' do
      expect(run(message_id: queued_message.id)).to contain_exactly(queued_message)
    end

    it 'accepts the webhook message id prefix' do
      expect(run(message_id: "msg_#{queued_message.id}")).to contain_exactly(queued_message)
    end

    it 'does not match a partial message id' do
      expect(run(message_id: queued_message.id[0, 8])).to be_empty
    end

    it 'finds a message by its exact request id' do
      expect(run(request_id: attempt.request_id)).to contain_exactly(queued_message)
    end

    it 'accepts a request id without the req prefix' do
      expect(run(request_id: 'exact-123')).to contain_exactly(queued_message)
    end

    it 'does not match a partial request id' do
      expect(run(request_id: 'exact')).to be_empty
    end

    it 'returns a message once even when several attempts share the request id' do
      create(:delivery_attempt, message: queued_message, attempt_number: 2, request_id: 'req-shared')
      create(:delivery_attempt, message: queued_message, attempt_number: 3, request_id: 'req-shared')

      expect(run(request_id: 'req-shared')).to contain_exactly(queued_message)
    end

    it 'returns a message once when the free text search matches several attempts' do
      create(:delivery_attempt, message: queued_message, attempt_number: 2, request_id: 'req-abc-shared')
      create(:delivery_attempt, message: queued_message, attempt_number: 3, request_id: 'req-abc-shared')

      expect(run(q: 'abc-shared')).to contain_exactly(queued_message)
    end
  end
end
