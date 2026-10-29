require 'rails_helper'

describe Projects::Create, type: :operation do
  let(:account) { create(:user) }

  describe '.call' do
    it 'creates the project and its owner membership' do
      project = described_class.call(user: account, attributes: { name: 'Alpha' })

      expect(project.project_memberships.pluck(:user_id, :role)).to eq([[account.id, 'owner']])
    end

    it 'records the creating account as the billing owner' do
      project = described_class.call(user: account, attributes: { name: 'Alpha' })

      expect(project.billing_owner_id).to eq(account.id)
      expect(account.owned_project_count).to eq(1)
    end

    it 'rolls back the project when owner membership creation fails' do
      allow_any_instance_of(ProjectMembership).to receive(:save!).and_raise(ActiveRecord::RecordInvalid.new(ProjectMembership.new))

      expect { described_class.call(user: account, attributes: { name: 'Alpha' }) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(Project.count).to eq(0)
    end
  end

  describe '.call with the account project limit' do
    context 'when the account reached the free project limit' do
      before { create_list(:project, 2, :with_owner, owner: account) }

      it 'rejects the project with a payment required error' do
        expect { described_class.call(user: account, attributes: { name: 'Alpha' }) }
          .to raise_error(ApiError::PlanLimitExceededError) { |error|
            expect(error.status).to eq(402)
            expect(error.code).to eq('plan_limit_exceeded')
            expect(error.errors).to contain_exactly(hash_including(field: 'project_limit'))
            expect(error.used).to eq(2)
            expect(error.limit).to eq(2)
          }

        expect(account.owned_project_count).to eq(2)
      end
    end

    context 'when the account is below the free project limit' do
      before { create(:project, :with_owner, owner: account) }

      it 'creates the project that fills the last slot' do
        project = described_class.call(user: account, attributes: { name: 'Alpha' })

        expect(project).to be_persisted
        expect(account.owned_project_count).to eq(2)
      end
    end

    context 'when the account only maintains projects owned by another account' do
      before do
        create_list(:project, 2, :with_owner).each do |project|
          create(:project_membership, project: project, user: account, role: :maintainer)
        end
      end

      it 'does not consume the owned project quota' do
        project = described_class.call(user: account, attributes: { name: 'Alpha' })

        expect(project).to be_persisted
        expect(account.owned_project_count).to eq(1)
      end
    end

    context 'when the account is on the pro plan' do
      let(:account) { create(:user, :pro) }

      before { create_list(:project, 2, :with_owner, owner: account) }

      it 'creates projects beyond the free limit' do
        project = described_class.call(user: account, attributes: { name: 'Alpha' })

        expect(project).to be_persisted
        expect(account.owned_project_count).to eq(3)
      end
    end
  end
end
