require 'rails_helper'

describe Plans::Entitlements do
  describe '.definition_for' do
    context 'when the plan is free' do
      it 'exposes the published free limits' do
        definition = described_class.definition_for(Project::FREE_PLAN)

        expect(definition.endpoint_limit).to eq(3)
        expect(definition.monthly_delivery_limit).to eq(10_000)
      end
    end

    context 'when the plan is pro' do
      it 'exposes the published pro limits' do
        definition = described_class.definition_for(Project::PRO_PLAN)

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
      expect(described_class::Definition.members).to contain_exactly(:endpoint_limit, :monthly_delivery_limit)
    end

    it 'keeps unreleased capabilities out of the exposed entitlements' do
      expect(described_class::DEFINITIONS.keys).to contain_exactly(Project::FREE_PLAN, Project::PRO_PLAN)
      expect(described_class::Definition.members).not_to include(*described_class::PLANNED_CAPABILITIES)
    end
  end

  describe '.endpoint_limit' do
    it 'reads the endpoint limit of the project plan' do
      free_project = build(:project, plan: Project::FREE_PLAN)
      pro_project = build(:project, plan: Project::PRO_PLAN)

      expect(described_class.endpoint_limit(free_project)).to eq(3)
      expect(described_class.endpoint_limit(pro_project)).to eq(50)
    end
  end

  describe '.monthly_delivery_limit' do
    it 'reads the monthly delivery limit of the project plan' do
      free_project = build(:project, plan: Project::FREE_PLAN)
      pro_project = build(:project, plan: Project::PRO_PLAN)

      expect(described_class.monthly_delivery_limit(free_project)).to eq(10_000)
      expect(described_class.monthly_delivery_limit(pro_project)).to eq(500_000)
    end
  end
end
