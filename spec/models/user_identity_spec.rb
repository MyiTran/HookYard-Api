require 'rails_helper'

describe UserIdentity, type: :model do
  describe 'validations' do
    subject(:identity) { build(:user_identity) }

    it { is_expected.to validate_presence_of(:provider) }
    it { is_expected.to validate_presence_of(:uid) }
    it { is_expected.to validate_presence_of(:email_at_provider) }
    it { is_expected.to validate_uniqueness_of(:uid).scoped_to(:provider) }
    it { is_expected.to validate_uniqueness_of(:provider).scoped_to(:user_id) }
  end

  describe 'associations' do
    it { is_expected.to belong_to(:user) }
  end
end
