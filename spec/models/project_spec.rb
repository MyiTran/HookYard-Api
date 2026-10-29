require 'rails_helper'

describe Project, type: :model do
  let(:project) { create(:project) }

  describe 'validations' do
    context 'when the billing owner is missing' do
      it 'is invalid' do
        project = build(:project, billing_owner: nil)

        expect(project).not_to be_valid
        expect(project.errors[:billing_owner]).to be_present
      end
    end

    context 'when a free account overrides the delivery timeout' do
      it 'is invalid' do
        project = build(:project, delivery_timeout_seconds: 20)

        expect(project).not_to be_valid
        expect(project.errors[:base]).to be_present
      end
    end

    context 'when a free account overrides the retry schedule' do
      it 'is invalid' do
        project = build(:project, delivery_retry_delays_seconds: [5])

        expect(project).not_to be_valid
        expect(project.errors[:base]).to be_present
      end
    end

    context 'when the billing owner is on the pro plan and configures a timeout inside the allowed range' do
      it 'is valid for the inclusive boundaries' do
        [1, 15, 30].each do |seconds|
          expect(build(:project, :pro, delivery_timeout_seconds: seconds)).to be_valid,
                                                                             "expected #{seconds} seconds to be accepted"
        end
      end

      it 'rejects a timeout outside the allowed range' do
        [0, 31, -5].each do |seconds|
          project = build(:project, :pro, delivery_timeout_seconds: seconds)

          expect(project).not_to be_valid, "expected #{seconds} seconds to be rejected"
          expect(project.errors[:delivery_timeout_seconds]).to be_present
        end
      end

      it 'rejects a non integer timeout' do
        project = build(:project, :pro, delivery_timeout_seconds: 2.5)

        expect(project).not_to be_valid
        expect(project.errors[:delivery_timeout_seconds]).to be_present
      end
    end

    context 'when the billing owner is on the pro plan and configures retry delays' do
      it 'is valid for positive delay values' do
        expect(build(:project, :pro, delivery_retry_delays_seconds: [5, 300, 3600])).to be_valid
      end

      it 'rejects zero or negative delays' do
        [[0], [-5]].each do |delays|
          project = build(:project, :pro, delivery_retry_delays_seconds: delays)

          expect(project).not_to be_valid, "expected #{delays.inspect} to be rejected"
          expect(project.errors[:delivery_retry_delays_seconds]).to be_present
        end
      end

      it 'rejects an empty retry schedule' do
        project = build(:project, :pro, delivery_retry_delays_seconds: [])

        expect(project).not_to be_valid
        expect(project.errors[:delivery_retry_delays_seconds]).to be_present
      end
    end
  end

  describe '#plan' do
    context 'when the billing owner is on the free plan' do
      it 'reports the free plan' do
        expect(project.plan).to eq(User::FREE_PLAN)
        expect(project).not_to be_pro
      end
    end

    context 'when the billing owner upgrades to the pro plan' do
      it 'follows the billing owner plan' do
        project.billing_owner.update!(plan: User::PRO_PLAN)

        expect(project.reload.plan).to eq(User::PRO_PLAN)
        expect(project).to be_pro
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
    let(:endpoint_limit) { Plans::Entitlements.endpoint_limit(project.billing_owner) }

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

    context 'when the billing owner is on the pro plan' do
      let(:project) { create(:project, :pro) }

      before do
        create_list(:endpoint, Plans::Entitlements.definition_for(User::FREE_PLAN).endpoint_limit, project: project)
      end

      it 'locks no endpoint within the pro limit' do
        expect(project.plan_locked_endpoint_ids).to be_empty
      end
    end
  end
end
