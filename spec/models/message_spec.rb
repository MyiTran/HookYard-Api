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

  describe 'validations' do
    context 'with the default factory' do
      it 'is valid' do
        expect(build(:message)).to be_valid
      end
    end

    context 'when the endpoint belongs to a different project than the event' do
      it 'is invalid' do
        message = build(:message, event: create(:event), endpoint: create(:endpoint))

        expect(message).not_to be_valid
        expect(message.errors[:base]).to be_present
      end
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
