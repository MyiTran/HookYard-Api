require 'rails_helper'

describe ProjectUsagePeriod, type: :model do
  let(:project) { create(:project) }
  let(:at) { Time.utc(2026, 10, 15, 9, 30) }

  def usage_period(time = at)
    described_class.find_by(project_id: project.id, period_starts_on: described_class.period_start_for(time))
  end

  describe '.period_start_for' do
    it 'starts the period on the first day of the month in UTC' do
      expect(described_class.period_start_for(at)).to eq(Date.new(2026, 10, 1))
    end

    it 'converts the time to UTC before resolving the month' do
      first_day_of_october_in_bangkok = Time.new(2026, 10, 1, 2, 0, 0, '+07:00')

      expect(described_class.period_start_for(first_day_of_october_in_bangkok)).to eq(Date.new(2026, 9, 1))
    end
  end

  describe '.period_starts_at' do
    it 'returns the exclusive start of the period in UTC' do
      expect(described_class.period_starts_at(at)).to eq(Time.utc(2026, 10, 1))
    end
  end

  describe '.period_ends_at' do
    it 'returns the exclusive end of the period in UTC' do
      expect(described_class.period_ends_at(at)).to eq(Time.utc(2026, 11, 1))
    end
  end

  describe '.used_deliveries' do
    context 'when the project has no usage in the period' do
      it 'returns zero' do
        expect(described_class.used_deliveries(project: project, at: at)).to eq(0)
      end
    end

    context 'when the project reserved deliveries in the period' do
      before { described_class.reserve_deliveries(project: project, quantity: 3, limit: 10, at: at) }

      it 'returns the reserved deliveries of that period' do
        expect(described_class.used_deliveries(project: project, at: at)).to eq(3)
      end

      it 'ignores other periods' do
        expect(described_class.used_deliveries(project: project, at: at.next_month)).to eq(0)
      end
    end
  end

  describe 'validations' do
    context 'when the delivery count is negative' do
      it 'is invalid' do
        period = described_class.new(project: project, period_starts_on: Date.new(2026, 10, 1), deliveries_count: -1)

        expect(period).not_to be_valid
        expect(period.errors[:deliveries_count]).to be_present
      end
    end
  end

  describe '.reserve_deliveries' do
    context 'when the project has no usage in the period yet' do
      it 'creates the period and counts the reserved deliveries' do
        reserved = described_class.reserve_deliveries(project: project, quantity: 2, limit: 5, at: at)

        expect(reserved).to be(true)
        expect(usage_period.deliveries_count).to eq(2)
      end
    end

    context 'when the project already reserved deliveries in the period' do
      before { described_class.reserve_deliveries(project: project, quantity: 2, limit: 5, at: at) }

      it 'adds to the same period counter' do
        described_class.reserve_deliveries(project: project, quantity: 3, limit: 5, at: at)

        expect(usage_period.deliveries_count).to eq(5)
        expect(described_class.where(project_id: project.id).count).to eq(1)
      end
    end

    context 'when the reservation would exceed the limit' do
      before { described_class.reserve_deliveries(project: project, quantity: 4, limit: 5, at: at) }

      it 'refuses the reservation and keeps the counter unchanged' do
        reserved = described_class.reserve_deliveries(project: project, quantity: 2, limit: 5, at: at)

        expect(reserved).to be(false)
        expect(usage_period.deliveries_count).to eq(4)
      end
    end

    context 'when the reservation reaches the limit exactly' do
      it 'accepts it' do
        reserved = described_class.reserve_deliveries(project: project, quantity: 5, limit: 5, at: at)

        expect(reserved).to be(true)
        expect(usage_period.deliveries_count).to eq(5)
      end
    end

    context 'when there is nothing to reserve' do
      it 'accepts without touching the counter' do
        reserved = described_class.reserve_deliveries(project: project, quantity: 0, limit: 5, at: at)

        expect(reserved).to be(true)
        expect(described_class.where(project_id: project.id)).to be_empty
      end
    end

    context 'when the remaining quota was consumed after the period was read' do
      before do
        described_class.reserve_deliveries(project: project, quantity: 3, limit: 5, at: at)
        usage_period.update_columns(deliveries_count: 5)
      end

      it 'refuses the reservation because the limit is checked in the database' do
        reserved = described_class.reserve_deliveries(project: project, quantity: 1, limit: 5, at: at)

        expect(reserved).to be(false)
        expect(usage_period.reload.deliveries_count).to eq(5)
      end
    end

    context 'when the period changes' do
      it 'keeps a separate counter per month' do
        described_class.reserve_deliveries(project: project, quantity: 5, limit: 5, at: at)

        next_month = Time.utc(2026, 11, 2, 9, 0)
        reserved = described_class.reserve_deliveries(project: project, quantity: 5, limit: 5, at: next_month)

        expect(reserved).to be(true)
        expect(usage_period.deliveries_count).to eq(5)
        expect(usage_period(next_month).deliveries_count).to eq(5)
      end
    end

    context 'when another project already used its quota' do
      before do
        other_project = create(:project)
        described_class.reserve_deliveries(project: other_project, quantity: 5, limit: 5, at: at)
      end

      it 'reserves against the current project only' do
        reserved = described_class.reserve_deliveries(project: project, quantity: 1, limit: 5, at: at)

        expect(reserved).to be(true)
        expect(usage_period.deliveries_count).to eq(1)
      end
    end
  end
end
