require 'rails_helper'

describe Plans::Entitlements do
  describe '.definition_for' do
    context 'when the plan is free' do
      it 'exposes the published free limits' do
        definition = described_class.definition_for(User::FREE_PLAN)

        expect(definition.project_limit).to eq(2)
        expect(definition.endpoint_limit).to eq(3)
        expect(definition.monthly_delivery_limit).to eq(10_000)
      end
    end

    context 'when the plan is pro' do
      it 'exposes the published pro limits' do
        definition = described_class.definition_for(User::PRO_PLAN)

        expect(definition.project_limit).to eq(10)
        expect(definition.endpoint_limit).to eq(50)
        expect(definition.monthly_delivery_limit).to eq(500_000)
      end
    end

    context 'when the plan is unknown' do
      it 'raises instead of granting an undefined plan' do
        expect { described_class.definition_for('enterprise') }.to raise_error(KeyError)
      end
    end
  end

  describe 'exposed entitlements' do
    it 'only exposes limits that are enforced today' do
      expect(described_class::Definition.members).to contain_exactly(:project_limit, :endpoint_limit, :monthly_delivery_limit)
    end

    it 'keeps unreleased capabilities out of the exposed entitlements' do
      expect(described_class::DEFINITIONS.keys).to contain_exactly(User::FREE_PLAN, User::PRO_PLAN)
      expect(described_class::Definition.members).not_to include(*described_class::PLANNED_CAPABILITIES)
    end
  end

  describe '.project_limit' do
    it 'reads the project limit of the account plan' do
      free_account = build(:user, plan: User::FREE_PLAN)
      pro_account = build(:user, plan: User::PRO_PLAN)

      expect(described_class.project_limit(free_account)).to eq(2)
      expect(described_class.project_limit(pro_account)).to eq(10)
    end
  end

  describe '.endpoint_limit' do
    it 'reads the endpoint limit of the account plan' do
      free_account = build(:user, plan: User::FREE_PLAN)
      pro_account = build(:user, plan: User::PRO_PLAN)

      expect(described_class.endpoint_limit(free_account)).to eq(3)
      expect(described_class.endpoint_limit(pro_account)).to eq(50)
    end
  end

  describe '.monthly_delivery_limit' do
    it 'reads the monthly delivery limit of the account plan' do
      free_account = build(:user, plan: User::FREE_PLAN)
      pro_account = build(:user, plan: User::PRO_PLAN)

      expect(described_class.monthly_delivery_limit(free_account)).to eq(10_000)
      expect(described_class.monthly_delivery_limit(pro_account)).to eq(500_000)
    end
  end
end
