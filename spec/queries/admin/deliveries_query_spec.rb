require 'rails_helper'

describe Admin::DeliveriesQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:other_project) { create(:project) }
  let(:other_endpoint) { create(:endpoint, project: other_project) }
  let(:scope) { Message.where(endpoint_id: [endpoint.id, other_endpoint.id]) }

  def run(**params)
    described_class.call(scope, **params)
  end

  def create_message(target_endpoint: endpoint, created_at: Time.current, **attributes)
    create(:message, project: target_endpoint.project, endpoint: target_endpoint, created_at: created_at, **attributes)
  end

  def create_attempt(message, attempt_number:, response_status: nil, error_type: nil)
    create(:delivery_attempt, message: message, attempt_number: attempt_number,
                              response_status: response_status, error_type: error_type)
  end

  def create_failed_message(**evidence)
    create_message.tap { |message| create_attempt(message, attempt_number: 1, **evidence) }
  end

  describe 'time window' do
    context 'with the default window' do
      it 'keeps the last seven days and drops older deliveries' do
        recent = create_message(created_at: 6.days.ago)
        create_message(created_at: 8.days.ago)

        expect(run.ids).to contain_exactly(recent.id)
      end
    end

    context 'when the requested range is wider than the maximum window' do
      it 'clamps the start of the window to ninety days' do
        inside = create_message(created_at: 89.days.ago)
        create_message(created_at: 91.days.ago)

        expect(run(from: 120.days.ago.iso8601).ids).to contain_exactly(inside.id)
      end
    end

    context 'when the range is anchored on an earlier end time' do
      it 'keeps only deliveries created inside the anchored range' do
        inside = create_message(created_at: 11.days.ago)
        create_message(created_at: 1.day.ago)

        expect(run(from: 12.days.ago.iso8601, to: 10.days.ago.iso8601).ids).to contain_exactly(inside.id)
      end
    end
  end

  describe 'failure category filter' do
    it 'filters failures by the category of the latest attempt' do
      http_error = create_failed_message(response_status: 503)
      timeout = create_failed_message(error_type: 'Net::ReadTimeout')
      network = create_failed_message(error_type: 'SocketError')
      destination_rejected = create_failed_message(
        error_type: 'Webhooks::DestinationResolver::NotPubliclyRoutable'
      )
      interrupted = create_failed_message(error_type: 'DeliveryLeaseExpired')

      expect(run(failure_category: Webhooks::FailureCategory::HTTP_ERROR).ids).to eq([http_error.id])
      expect(run(failure_category: Webhooks::FailureCategory::TIMEOUT).ids).to eq([timeout.id])
      expect(run(failure_category: Webhooks::FailureCategory::NETWORK).ids).to eq([network.id])
      expect(run(failure_category: Webhooks::FailureCategory::DESTINATION_REJECTED).ids).to eq([destination_rejected.id])
      expect(run(failure_category: Webhooks::FailureCategory::INTERRUPTED).ids).to eq([interrupted.id])
    end

    context 'when the delivery succeeded' do
      it 'never classifies it as a failure' do
        create_failed_message(response_status: 200)

        expect(run(failure_category: Webhooks::FailureCategory::HTTP_ERROR).ids).to be_empty
        expect(run(failure_category: Webhooks::FailureCategory::NETWORK).ids).to be_empty
      end
    end

    context 'with an unknown category' do
      it 'ignores the filter' do
        create_failed_message(response_status: 500)

        expect(run(failure_category: 'made_up').to_a.size).to eq(1)
      end
    end
  end

  describe 'scope filters' do
    it 'filters by status, endpoint and project' do
      failed_message = create_message(status: :failed)
      succeeded_message = create_message(status: :succeeded)
      foreign_message = create_message(target_endpoint: other_endpoint, status: :failed)

      expect(run(status: 'failed').ids).to contain_exactly(failed_message.id, foreign_message.id)
      expect(run(endpoint_id: endpoint.id).ids).to contain_exactly(failed_message.id, succeeded_message.id)
      expect(run(project_id: other_project.id).ids).to contain_exactly(foreign_message.id)
    end

    it 'lists the newest deliveries first' do
      older = create_message(created_at: 3.days.ago)
      newer = create_message(created_at: 1.day.ago)

      expect(run.ids).to eq([newer.id, older.id])
    end

    it 'filters by the project billing owner, not by project membership' do
      owner = create(:user)
      owned_project = create(:project, billing_owner: owner)
      owned_endpoint = create(:endpoint, project: owned_project)
      owned_message = create_message(target_endpoint: owned_endpoint)

      joined_project = create(:project, billing_owner: create(:user))
      create(:project_membership, project: joined_project, user: owner, role: :maintainer)
      joined_endpoint = create(:endpoint, project: joined_project)
      create_message(target_endpoint: joined_endpoint)

      expect(described_class.call(Message.all, account_id: owner.id).ids).to contain_exactly(owned_message.id)
    end

    it 'ignores an invalid account id' do
      create_message

      expect(described_class.call(Message.all, account_id: 'not-a-uuid')).not_to be_empty
    end
  end
end
