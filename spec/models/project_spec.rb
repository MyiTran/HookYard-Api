require 'rails_helper'

describe Project, type: :model do
  let(:project) { create(:project) }
  let(:current_period_start) { ProjectUsagePeriod.period_start_for(Time.current) }

  describe 'validations' do
    context 'when the plan is a supported tenant plan' do
      it 'is valid' do
        expect(build(:project, plan: 'free')).to be_valid
        expect(build(:project, plan: 'pro')).to be_valid
      end
    end

    context 'when the plan is unknown' do
      it 'is invalid' do
        project = build(:project, plan: 'enterprise')

        expect(project).not_to be_valid
        expect(project.errors[:plan]).to be_present
      end
    end

    context 'when a free tenant overrides the delivery timeout' do
      it 'is invalid' do
        project = build(:project, plan: 'free', delivery_timeout_seconds: 20)

        expect(project).not_to be_valid
        expect(project.errors[:base]).to be_present
      end
    end

    context 'when a free tenant overrides the retry schedule' do
      it 'is invalid' do
        project = build(:project, plan: 'free', delivery_retry_delays_seconds: [5])

        expect(project).not_to be_valid
        expect(project.errors[:base]).to be_present
      end
    end

    context 'when a pro tenant configures a timeout inside the allowed range' do
      it 'is valid for the inclusive boundaries' do
        expect(build(:project, plan: 'pro', delivery_timeout_seconds: 1)).to be_valid
        expect(build(:project, plan: 'pro', delivery_timeout_seconds: 15)).to be_valid
        expect(build(:project, plan: 'pro', delivery_timeout_seconds: 30)).to be_valid
      end

      it 'rejects a timeout outside the allowed range' do
        [0, 31, -5].each do |seconds|
          project = build(:project, plan: 'pro', delivery_timeout_seconds: seconds)

          expect(project).not_to be_valid, "expected #{seconds} seconds to be rejected"
          expect(project.errors[:delivery_timeout_seconds]).to be_present
        end
      end

      it 'rejects a non integer timeout' do
        project = build(:project, plan: 'pro', delivery_timeout_seconds: 2.5)

        expect(project).not_to be_valid
        expect(project.errors[:delivery_timeout_seconds]).to be_present
      end
    end

    context 'when a pro tenant configures retry delays' do
      it 'is valid for positive delay values' do
        expect(build(:project, plan: 'pro', delivery_retry_delays_seconds: [5, 300, 3600])).to be_valid
      end

      it 'rejects zero or negative delays' do
        [[0], [-5]].each do |delays|
          project = build(:project, plan: 'pro', delivery_retry_delays_seconds: delays)

          expect(project).not_to be_valid, "expected #{delays.inspect} to be rejected"
          expect(project.errors[:delivery_retry_delays_seconds]).to be_present
        end
      end

      it 'rejects an empty retry schedule' do
        project = build(:project, plan: 'pro', delivery_retry_delays_seconds: [])

        expect(project).not_to be_valid
        expect(project.errors[:delivery_retry_delays_seconds]).to be_present
      end
    end
  end

  describe '#deliveries_used_in_period' do
    context 'when the project has no metered usage' do
      it 'returns zero' do
        expect(project.deliveries_used_in_period).to eq(0)
      end
    end

    context 'when the project has metered usage for the current month' do
      before do
        ProjectUsagePeriod.create!(
          project: project,
          period_starts_on: current_period_start,
          deliveries_count: 7
        )
      end

      it 'returns the current period count' do
        expect(project.deliveries_used_in_period).to eq(7)
      end
    end

    context 'when the project has metered usage for another month' do
      before do
        ProjectUsagePeriod.create!(
          project: project,
          period_starts_on: current_period_start - 1.month,
          deliveries_count: 12
        )
      end

      it 'ignores the other period' do
        expect(project.deliveries_used_in_period).to eq(0)
      end
    end
  end

  describe '#endpoint_count' do
    context 'when the project has active endpoints' do
      before { create_list(:endpoint, 2, project: project) }

      it 'counts them' do
        expect(project.endpoint_count).to eq(2)
      end
    end

    context 'when the project has archived endpoints' do
      before do
        create(:endpoint, project: project)
        create(:endpoint, project: project, archived_at: Time.current)
      end

      it 'counts only the non-archived endpoints' do
        expect(project.endpoint_count).to eq(1)
      end
    end
  end

  describe '#plan_locked_endpoint_ids' do
    let(:endpoint_limit) { Plans::Entitlements.endpoint_limit(project) }

    context 'when the project is within its endpoint limit' do
      before { create_list(:endpoint, endpoint_limit, project: project) }

      it 'locks no endpoint' do
        expect(project.plan_locked_endpoint_ids).to be_empty
      end
    end

    context 'when the project has more endpoints than its plan allows' do
      let!(:endpoints) do
        Array.new(endpoint_limit + 2) do |index|
          create(:endpoint, project: project, created_at: Time.utc(2026, 10, 1, 9, 0) + index.minutes)
        end
      end

      it 'locks the endpoints created after the limit' do
        expect(project.plan_locked_endpoint_ids).to match_array(endpoints.last(2).map(&:id))
      end
    end

    context 'when the endpoints were created at the same time' do
      let(:created_at) { Time.utc(2026, 10, 15, 9, 30) }
      let!(:endpoints) do
        create_list(:endpoint, endpoint_limit + 2, project: project, created_at: created_at).sort_by(&:id)
      end

      it 'locks the endpoints with the highest ids' do
        expect(project.plan_locked_endpoint_ids).to match_array(endpoints.last(2).map(&:id))
      end

      it 'returns the same set on every call' do
        first_call = project.plan_locked_endpoint_ids
        second_call = project.plan_locked_endpoint_ids

        expect(second_call).to eq(first_call)
      end
    end

    context 'when the project has archived endpoints beyond the limit' do
      let!(:active_endpoints) do
        Array.new(endpoint_limit + 2) do |index|
          create(:endpoint, project: project, created_at: Time.utc(2026, 10, 1, 9, 0) + index.minutes)
        end
      end

      before do
        Array.new(3) do |index|
          create(:endpoint, project: project, created_at: Time.utc(2026, 12, 1, 9, 0) + index.minutes, archived_at: Time.current)
        end
      end

      it 'does not let archived endpoints consume a plan slot' do
        expect(project.plan_locked_endpoint_ids).to match_array(active_endpoints.last(2).map(&:id))
      end
    end

    context 'when the project is on the pro plan' do
      let(:project) { create(:project, plan: Project::PRO_PLAN) }

      before do
        create_list(:endpoint, Plans::Entitlements.definition_for(Project::FREE_PLAN).endpoint_limit, project: project)
      end

      it 'locks no endpoint within the pro limit' do
        expect(project.plan_locked_endpoint_ids).to be_empty
      end
    end
  end
end
