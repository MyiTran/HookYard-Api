require 'rails_helper'

describe IngestRejectionsQuery do
  let(:project) { create(:project) }
  let(:scope) { IngestRejection.all }
  let(:now) { Time.zone.local(2026, 11, 3, 10, 0, 0) }

  let!(:queue_rejection) do
    create(:ingest_rejection, project: project, event_type: 'order.created', created_at: now - 1.hour)
  end
  let!(:quota_rejection) do
    create(
      :ingest_rejection,
      project: project,
      reason: IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED,
      event_type: 'invoice.paid',
      created_at: now - 3.days
    )
  end

  def run(**params)
    described_class.call(scope, **params)
  end

  describe 'filters' do
    it 'returns every rejection by default in newest-first order' do
      expect(run).to eq([queue_rejection, quota_rejection])
    end

    it 'filters by reason' do
      expect(run(reason: IngestRejection::MONTHLY_DELIVERY_LIMIT_EXCEEDED)).to contain_exactly(quota_rejection)
    end

    it 'ignores an unknown reason instead of matching nothing' do
      expect(run(reason: 'unknown')).to contain_exactly(queue_rejection, quota_rejection)
    end

    it 'filters by event type' do
      expect(run(event_type: 'order.created')).to contain_exactly(queue_rejection)
    end

    it 'filters by project' do
      other = create(:ingest_rejection, project: create(:project))

      expect(run(project_id: project.id)).to contain_exactly(queue_rejection, quota_rejection)
      expect(run(project_id: other.project_id)).to contain_exactly(other)
    end

    it 'ignores an invalid project id' do
      expect(run(project_id: 'not-a-uuid')).to contain_exactly(queue_rejection, quota_rejection)
    end

    it 'filters by the utc created-at range' do
      expect(run(from: (now - 2.hours).iso8601)).to contain_exactly(queue_rejection)
      expect(run(to: (now - 2.hours).iso8601)).to contain_exactly(quota_rejection)
    end

    it 'orders oldest first when requested' do
      expect(run(order: 'created_asc')).to eq([quota_rejection, queue_rejection])
    end
  end
end
