require 'rails_helper'

describe Message, type: :model do
  describe 'status constraint' do
    context 'when an unknown status is written' do
      it 'is rejected by the database' do
        message = create(:message)

        expect { message.update_column(:status, 'unknown') }
          .to raise_error(ActiveRecord::StatementInvalid)
      end
    end
  end

  describe '#webhook_id' do
    it 'stays stable for the message' do
      message = create(:message)

      expect(message.webhook_id).to eq("msg_#{message.id}")
      expect(message.webhook_id).to eq(message.reload.webhook_id)
    end
  end

  describe 'delivery target uniqueness' do
    let(:project) { create(:project) }
    let(:endpoint) { create(:endpoint, project: project) }
    let(:event) { create(:event, project: project) }

    it 'allows only one message per event and endpoint' do
      create(:message, event: event, endpoint: endpoint)

      expect { create(:message, event: event, endpoint: endpoint) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
