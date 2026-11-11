require 'rails_helper'

describe Admin::SupportAccountsQuery do
  let(:fixture_emails) do
    %w[ada@example.com grace@example.com linus@example.com margaret@example.com]
  end
  let(:scope) { User.where(email: fixture_emails) }

  let!(:admin_account) do
    create(:user, email: 'ada@example.com', first_name: 'Ada', last_name: 'Lovelace', created_at: 3.days.ago)
      .tap { |user| user.add_role(:admin) }
  end
  let!(:support_account) do
    create(:user, email: 'grace@example.com', first_name: 'Grace', last_name: 'Hopper', created_at: 2.days.ago)
      .tap { |user| user.add_role(:support) }
  end
  let!(:pro_customer) do
    create(:user, :pro, email: 'linus@example.com', first_name: 'Linus', last_name: 'Torvalds',
                   created_at: 1.day.ago)
  end

  let!(:unconfirmed_customer) do
    create(:user, :need_confirmation, email: 'margaret@example.com', first_name: 'Margaret', last_name: 'Hamilton',
                                      created_at: 4.days.ago)
  end

  def run(**params)
    described_class.call(scope, **params)
  end

  describe 'ordering' do
    context 'with the default order' do
      it 'lists the newest accounts first' do
        expect(run.map(&:id)).to eq([pro_customer.id, support_account.id, admin_account.id, unconfirmed_customer.id])
      end
    end

    context 'with the email order' do
      it 'sorts accounts by email' do
        expect(run(order: 'email_asc').map(&:id)).to eq(
          [admin_account.id, support_account.id, pro_customer.id, unconfirmed_customer.id]
        )
      end
    end

    context 'with an unknown order' do
      it 'falls back to the default order' do
        expect(run(order: 'last_sign_in_desc').map(&:id)).to eq(
          [pro_customer.id, support_account.id, admin_account.id, unconfirmed_customer.id]
        )
      end
    end
  end

  describe 'search' do
    it 'matches email, first name and last name case insensitively' do
      expect(run(q: 'HOPPER').map(&:id)).to eq([support_account.id])
      expect(run(q: 'linus@example').map(&:id)).to eq([pro_customer.id])
      expect(run(q: 'hamilton').map(&:id)).to eq([unconfirmed_customer.id])
    end

    it 'treats SQL wildcards in the search term as literals' do
      expect(run(q: '%')).to be_empty
    end
  end

  describe 'role filter' do
    it 'filters administrators' do
      expect(run(role: 'admin').map(&:id)).to eq([admin_account.id])
    end

    it 'filters support accounts' do
      expect(run(role: 'support').map(&:id)).to eq([support_account.id])
    end

    it 'filters accounts without any role' do
      expect(run(role: 'none').map(&:id)).to contain_exactly(pro_customer.id, unconfirmed_customer.id)
    end

    it 'ignores an unsupported role' do
      expect(run(role: 'owner').count).to eq(4)
    end
  end

  describe 'plan filter' do
    it 'filters free accounts' do
      expect(run(plan: 'free').map(&:id)).to contain_exactly(support_account.id, unconfirmed_customer.id)
    end

    it 'filters pro accounts' do
      expect(run(plan: 'pro').map(&:id)).to contain_exactly(pro_customer.id)
    end

    it 'excludes administrator accounts from both plan filters' do
      expect(run(plan: 'free').map(&:id)).not_to include(admin_account.id)
      expect(run(plan: 'pro').map(&:id)).not_to include(admin_account.id)
    end

    it 'ignores an unknown plan' do
      expect(run(plan: 'enterprise').count).to eq(4)
    end

    it 'treats SQL fragments as an unknown plan' do
      expect { run(plan: "'; DROP TABLE users;--") }.not_to raise_error
      expect(run(plan: "'; DROP TABLE users;--").count).to eq(4)
    end
  end

  describe 'active filter' do
    it 'filters confirmed accounts' do
      expect(run(active: true).map(&:id)).to contain_exactly(admin_account.id, support_account.id, pro_customer.id)
    end

    it 'filters unconfirmed accounts' do
      expect(run(active: false).map(&:id)).to eq([unconfirmed_customer.id])
    end
  end
end
