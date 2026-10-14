require 'rails_helper'

describe NotificationsChannel do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:stream) { described_class.broadcasting_for(user) }

  before { clear_cable_messages(stream) }

  describe 'subscription' do
    before { stub_connection(current_user: user) }

    it 'streams for the current user' do
      subscribe

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_for(user)
    end
  end

  describe '.broadcast_created' do
    it 'signals the notification owner only' do
      described_class.broadcast_created(create(:notification, user: user))

      expect(cable_messages(stream)).to eq([{ 'type' => 'notification.created' }])
      expect(cable_messages(described_class.broadcasting_for(other_user))).to be_empty
    end
  end

  describe '.broadcast_removed' do
    it 'signals the given user' do
      described_class.broadcast_removed(user)

      expect(cable_messages(stream)).to eq([{ 'type' => 'notification.removed' }])
      expect(cable_messages(described_class.broadcasting_for(other_user))).to be_empty
    end
  end
end
