require 'rails_helper'

describe Notification do
  it { is_expected.to belong_to(:user) }
  it { is_expected.to belong_to(:actor).class_name('User').optional }
  it { is_expected.to belong_to(:project).optional }
  it { is_expected.to belong_to(:project_invitation).optional }

  describe 'kinds' do
    it 'only exposes the invitation kinds' do
      expect(described_class.kinds.keys).to contain_exactly(
        'project_invitation_received', 'project_invitation_accepted', 'project_invitation_declined'
      )
    end
  end

  describe '.recent' do
    it 'returns the notifications of the last 30 days, newest first' do
      older = create(:notification, created_at: 2.days.ago)
      newer = create(:notification, created_at: 1.day.ago)
      create(:notification, created_at: 31.days.ago)

      expect(described_class.recent).to eq([newer, older])
    end
  end

  describe '.unread' do
    it 'only includes notifications without a read_at' do
      unread = create(:notification)
      create(:notification, read_at: Time.current)

      expect(described_class.unread).to contain_exactly(unread)
    end
  end
end
