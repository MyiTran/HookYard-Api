require 'rails_helper'

describe DeliveryMetric, type: :model do
  describe 'validations' do
    it 'requires non-negative counters' do
      metric = build(:delivery_metric, attempts_count: -1, successes_count: -1, failures_count: -1)

      expect(metric).not_to be_valid
      expect(metric.errors[:attempts_count]).to be_present
      expect(metric.errors[:successes_count]).to be_present
      expect(metric.errors[:failures_count]).to be_present
    end
  end

  describe '.record_attempt!' do
    let(:project) { create(:project) }
    let(:endpoint) { create(:endpoint, project: project) }
    let(:message) { create(:message, project: project, endpoint: endpoint) }

    def attempt(response_status: 200, error_type: nil)
      create(
        :delivery_attempt,
        message: message,
        response_status: response_status,
        error_type: error_type,
        metrics_recorded_at: nil
      )
    end

    it 'rolls up one successful attempt per project and day' do
      described_class.record_attempt!(attempt(response_status: 201))

      metric = described_class.find_by!(project: project, day: Date.current)
      expect(metric.attempts_count).to eq(1)
      expect(metric.successes_count).to eq(1)
      expect(metric.failures_count).to eq(0)
    end

    it 'rolls up transport failures separately from success' do
      described_class.record_attempt!(attempt(response_status: 200))
      described_class.record_attempt!(attempt(response_status: nil, error_type: 'Net::ReadTimeout'))

      metric = described_class.find_by!(project: project, day: Date.current)
      expect(metric.attempts_count).to eq(2)
      expect(metric.successes_count).to eq(1)
      expect(metric.failures_count).to eq(1)
    end

    it 'does not count the same attempt twice' do
      delivery_attempt = attempt(response_status: 200)

      2.times { described_class.record_attempt!(delivery_attempt) }

      metric = described_class.find_by!(project: project, day: Date.current)
      expect(metric.attempts_count).to eq(1)
    end

    it 'ignores an attempt that has not completed' do
      delivery_attempt = create(:delivery_attempt, message: message, response_status: nil, error_type: nil)

      described_class.record_attempt!(delivery_attempt)

      expect(described_class.count).to eq(0)
    end
  end

  describe '.backfill_missing!' do
    let(:project) { create(:project) }
    let(:other_project) { create(:project) }
    let(:endpoint) { create(:endpoint, project: project) }
    let(:other_endpoint) { create(:endpoint, project: other_project) }
    let(:message) { create(:message, project: project, endpoint: endpoint) }
    let(:other_message) { create(:message, project: other_project, endpoint: other_endpoint) }
    let(:day) { 3.days.ago.utc.to_date }

    def completed_attempt(message:, response_status: 200, error_type: nil)
      create(
        :delivery_attempt,
        message: message,
        response_status: response_status,
        error_type: error_type,
        metrics_recorded_at: nil,
        created_at: day.to_time(:utc) + 1.hour
      )
    end

    it 'creates metrics for completed historical attempts' do
      completed_attempt(message: message, response_status: 201)
      completed_attempt(message: message, response_status: 500)
      completed_attempt(message: message, response_status: nil, error_type: 'Net::ReadTimeout')

      expect { described_class.backfill_missing! }.to change(described_class, :count).by(1)

      metric = described_class.find_by!(project: project, day: day)
      expect(metric.attempts_count).to eq(3)
      expect(metric.successes_count).to eq(1)
      expect(metric.failures_count).to eq(2)
    end

    it 'keeps project buckets isolated' do
      completed_attempt(message: message, response_status: 201)
      completed_attempt(message: other_message, response_status: 422)

      described_class.backfill_missing!

      expect(described_class.find_by!(project: project, day: day).attempts_count).to eq(1)
      expect(described_class.find_by!(project: other_project, day: day).attempts_count).to eq(1)
    end

    it 'ignores attempts that have not completed' do
      create(
        :delivery_attempt,
        message: message,
        response_status: nil,
        error_type: nil,
        metrics_recorded_at: nil,
        created_at: day.to_time(:utc) + 1.hour
      )

      expect { described_class.backfill_missing! }.not_to change(described_class, :count)
    end

    it 'is idempotent and does not count an attempt twice' do
      completed_attempt(message: message, response_status: 200)

      2.times { described_class.backfill_missing! }

      metric = described_class.find_by!(project: project, day: day)
      expect(metric.attempts_count).to eq(1)
      expect(metric.successes_count).to eq(1)
      expect(metric.failures_count).to eq(0)
    end

    it 'adds missing attempts to an existing metric bucket' do
      create(
        :delivery_metric,
        project: project,
        day: day,
        attempts_count: 4,
        successes_count: 3,
        failures_count: 1
      )
      completed_attempt(message: message, response_status: 200)

      described_class.backfill_missing!

      metric = described_class.find_by!(project: project, day: day)
      expect(metric.attempts_count).to eq(5)
      expect(metric.successes_count).to eq(4)
      expect(metric.failures_count).to eq(1)
    end
  end
end
