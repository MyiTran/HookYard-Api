require 'rails_helper'

describe Notification, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:actor).class_name('User').optional }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:project_invitation).optional }
  end

  describe '.recent' do
    context 'when notifications are within the last 30 days' do
      it 'returns them newest first' do
        older = create(:notification, created_at: 2.days.ago)
        newer = create(:notification, created_at: 1.day.ago)

        expect(described_class.recent).to eq([newer, older])
      end
    end

    context 'when a notification is older than 30 days' do
      it 'excludes it' do
        recent = create(:notification, created_at: 1.day.ago)
        create(:notification, created_at: 31.days.ago)

        expect(described_class.recent).to contain_exactly(recent)
      end
    end
  end

  describe '.unread' do
    context 'when read_at is nil' do
      it 'includes the notification' do
        notification = create(:notification)

        expect(described_class.unread).to contain_exactly(notification)
      end
    end

    context 'when read_at is present' do
      it 'excludes the notification' do
        create(:notification, read_at: Time.current)

        expect(described_class.unread).to be_empty
      end
    end
  end
end
