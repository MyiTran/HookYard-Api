require 'rails_helper'

describe Replays::RecoverStaleLeases, type: :operation do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }
  let(:message) { create(:message, event: event, endpoint: endpoint) }
  let(:run) { create(:replay_run, project: project) }
  let(:item) do
    create(:replay_item, replay_run: run, message: message, endpoint: endpoint,
                         status: ReplayItem::DELIVERING_STATUS)
  end
  let(:now) { Time.zone.local(2026, 1, 1, 12, 0, 0) }

  before { travel_to(now) }

  def start_delivery(record, lease_expires_at:)
    record.update_columns(
      status: ReplayItem::DELIVERING_STATUS,
      delivery_lease_expires_at: lease_expires_at,
      started_at: 1.minute.ago
    )
  end

  describe '.call' do
    context 'when the lease expired during a replay attempt' do
      before do
        start_delivery(item, lease_expires_at: 1.minute.ago)
        create(:delivery_attempt, message: message, attempt_number: 1, replay_item: item,
                                  request_url: endpoint.url, request_body: '{"id":"evt"}')
      end

      it 'terminally fails the item and releases the lease' do
        described_class.call

        item.reload
        expect(item.status).to eq(ReplayItem::FAILED_STATUS)
        expect(item.completed_at).to eq(now)
        expect(item.delivery_lease_expires_at).to be_nil
        expect(item.error_type).to eq(ReplayItem::LEASE_EXPIRED_ERROR_TYPE)
        expect(item.error_message).to eq(ReplayItem::LEASE_EXPIRED_MESSAGE)
      end

      it 'abandons the in-progress attempt with the lease expiry error' do
        described_class.call

        attempt = item.delivery_attempt.reload
        expect(attempt.error_type).to eq(DeliveryAttempt::LEASE_EXPIRED_ERROR_TYPE)
        expect(attempt.error_message).to eq(DeliveryAttempt::LEASE_EXPIRED_MESSAGE)
        expect(attempt.response_status).to be_nil
      end

      it 'leaves the original message status untouched' do
        described_class.call

        expect(message.reload.status).not_to eq('succeeded')
      end
    end

    context 'when the lease is still active' do
      before { start_delivery(item, lease_expires_at: 5.minutes.from_now) }

      it 'leaves the in-progress delivery untouched' do
        described_class.call

        expect(item.reload.status).to eq(ReplayItem::DELIVERING_STATUS)
        expect(item.delivery_lease_expires_at).to be_present
      end
    end

    context 'when the item is already terminal' do
      before { item.update!(status: ReplayItem::SUCCEEDED_STATUS, completed_at: now) }

      it 'does not overwrite the terminal state' do
        described_class.call

        expect(item.reload.status).to eq(ReplayItem::SUCCEEDED_STATUS)
      end
    end

    context 'when the expired item has no attempt' do
      before { start_delivery(item, lease_expires_at: 1.minute.ago) }

      it 'fails the item without touching attempts' do
        expect { described_class.call }.not_to change(DeliveryAttempt, :count)

        expect(item.reload.status).to eq(ReplayItem::FAILED_STATUS)
      end
    end
  end
end
