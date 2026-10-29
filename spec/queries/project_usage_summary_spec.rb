require 'rails_helper'

describe ProjectUsageSummary do
  let(:at) { Time.utc(2026, 10, 15, 9, 30) }
  let(:account) { create(:user) }
  let(:other_account) { create(:user) }
  let(:projects) { create_list(:project, 2, owner: account) + [create(:project, owner: other_account)] }

  describe '#deliveries_for' do
    context 'when the billing accounts metered deliveries in the current period' do
      before do
        UserUsagePeriod.reserve_deliveries(user: account, quantity: 4, limit: 100, at: at)
        UserUsagePeriod.reserve_deliveries(user: other_account, quantity: 1, limit: 100, at: at)
      end

      it 'reports the monthly usage of each project billing account' do
        summary = described_class.new(projects, at: at)

        expect(summary.deliveries_for(projects.first)).to eq(4)
        expect(summary.deliveries_for(projects.second)).to eq(4)
        expect(summary.deliveries_for(projects.third)).to eq(1)
      end
    end

    context 'when a billing account only metered deliveries in another period' do
      before { UserUsagePeriod.reserve_deliveries(user: account, quantity: 9, limit: 100, at: at - 1.month) }

      it 'reports the current period only' do
        expect(described_class.new(projects, at: at).deliveries_for(projects.first)).to eq(0)
      end
    end
  end

  describe '#endpoint_count_for' do
    context 'when the projects have active and archived endpoints' do
      before do
        create_list(:endpoint, 2, project: projects.first)
        create(:endpoint, project: projects.first, archived_at: Time.current)
        create(:endpoint, project: projects.third)
      end

      it 'counts the non-archived endpoints per project' do
        summary = described_class.new(projects)

        expect(summary.endpoint_count_for(projects.first)).to eq(2)
        expect(summary.endpoint_count_for(projects.second)).to eq(0)
        expect(summary.endpoint_count_for(projects.third)).to eq(1)
      end
    end
  end

  describe 'query count' do
    it 'reads the usage of any number of projects with the same number of queries' do
      create_list(:endpoint, 2, project: projects.first)
      UserUsagePeriod.reserve_deliveries(user: account, quantity: 2, limit: 100, at: at)
      single_summary = described_class.new([projects.first], at: at)
      many_summary = described_class.new(projects, at: at)

      single_queries = sql_queries do
        single_summary.deliveries_for(projects.first)
        single_summary.endpoint_count_for(projects.first)
      end
      many_queries = sql_queries do
        projects.each do |project|
          many_summary.deliveries_for(project)
          many_summary.endpoint_count_for(project)
        end
      end

      expect(many_queries.length).to eq(single_queries.length)
    end
  end
end
