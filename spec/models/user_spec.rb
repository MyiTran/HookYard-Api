require 'rails_helper'

# == Schema Information
#
# Table name: users
#
#  id                     :uuid             not null, primary key
#  confirmation_sent_at   :datetime
#  confirmation_token     :string
#  confirmed_at           :datetime
#  current_sign_in_at     :datetime
#  current_sign_in_ip     :string
#  email                  :string           default(""), not null
#  encrypted_password     :string           default(""), not null
#  first_name             :string           default(""), not null
#  last_name              :string           default(""), not null
#  last_sign_in_at        :datetime
#  last_sign_in_ip        :string
#  reset_password_sent_at :datetime
#  reset_password_token   :string
#  sign_in_count          :integer          default(0), not null
#  unconfirmed_email      :string
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  plan                   :string           default("free"), not null
#
# Indexes
#
#  index_users_on_confirmation_token    (confirmation_token) UNIQUE
#  index_users_on_email                 (email) UNIQUE
#  index_users_on_reset_password_token  (reset_password_token) UNIQUE
#
describe User, type: :model do
  subject { build(:user) }

  describe 'validates' do
    it { is_expected.to validate_presence_of(:email) }
    it { is_expected.to validate_uniqueness_of(:email).case_insensitive }
    it { is_expected.to validate_presence_of(:password) }
    it { is_expected.to validate_length_of(:password).is_at_least(8).is_at_most(128) }
    it { is_expected.to validate_presence_of(:first_name) }
    it { is_expected.to validate_presence_of(:last_name) }
  end

  describe 'plan validation' do
    context 'when the plan is a supported account plan' do
      it 'is valid' do
        expect(build(:user, plan: User::FREE_PLAN)).to be_valid
        expect(build(:user, plan: User::PRO_PLAN)).to be_valid
      end
    end

    context 'when the plan is unknown' do
      it 'is invalid' do
        user = build(:user, plan: 'enterprise')

        expect(user).not_to be_valid
        expect(user.errors[:plan]).to be_present
      end
    end
  end

  describe '#owned_project_count' do
    context 'when the account owns projects' do
      let(:account) { create(:user) }

      before do
        create_list(:project, 2, :with_owner, owner: account)
        create(:project, :with_owner, owner: account)
        create(:project, :with_owner)
      end

      it 'counts the projects it is the billing owner of' do
        expect(account.owned_project_count).to eq(3)
      end
    end

    context 'when the account only joined other projects as a member' do
      let(:member) { create(:user) }
      let(:project) { create(:project, :with_owner) }

      before { create(:project_membership, project: project, user: member, role: :maintainer) }

      it 'does not count projects owned by another account' do
        expect(member.owned_project_count).to eq(0)
      end
    end

    context 'when the account owns one project and maintains another account project' do
      let(:account) { create(:user) }

      before do
        create(:project, :with_owner, owner: account)
        other_project = create(:project, :with_owner)
        create(:project_membership, project: other_project, user: account, role: :maintainer)
      end

      it 'counts only the projects it is the billing owner of' do
        expect(account.owned_project_count).to eq(1)
      end
    end
  end

  describe '#deliveries_used_in_period' do
    let(:account) { create(:user) }

    context 'when the account has no metered usage' do
      it 'returns zero' do
        expect(account.deliveries_used_in_period).to eq(0)
      end
    end

    context 'when the account has metered usage for the current month' do
      before do
        UserUsagePeriod.create!(
          user: account,
          period_starts_on: UserUsagePeriod.period_start_for(Time.current),
          deliveries_count: 7
        )
      end

      it 'returns the current period count' do
        expect(account.deliveries_used_in_period).to eq(7)
      end
    end

    context 'when the account has metered usage for another month' do
      before do
        UserUsagePeriod.create!(
          user: account,
          period_starts_on: UserUsagePeriod.period_start_for(Time.current) - 1.month,
          deliveries_count: 12
        )
      end

      it 'ignores the other period' do
        expect(account.deliveries_used_in_period).to eq(0)
      end
    end
  end
end
