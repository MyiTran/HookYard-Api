require 'rails_helper'

describe Project, type: :model do
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
end
