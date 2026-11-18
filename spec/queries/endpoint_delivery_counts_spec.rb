require 'rails_helper'

describe EndpointDeliveryCounts do
  describe '#for' do
    it 'returns zero counters for an endpoint without messages' do
      endpoint = create(:endpoint)

      expect(described_class.new([endpoint]).for(endpoint)).to eq(
        backlog_total: 0,
        held_count: 0,
        dispatchable_count: 0
      )
    end

    it 'preloads backlog, held, and dispatchable counts across endpoints' do
      endpoint_a = create(:endpoint)
      endpoint_b = create(:endpoint)

      create(:message, project: endpoint_a.project, endpoint: endpoint_a, status: :pending)
      create(:message, project: endpoint_a.project, endpoint: endpoint_a, status: :pending, held_at: Time.current, hold_reason: 'endpoint_disabled')
      create(:message, project: endpoint_b.project, endpoint: endpoint_b, status: :delivering)

      counts = described_class.new([endpoint_a, endpoint_b])

      expect(counts.for(endpoint_a)).to eq(
        backlog_total: 2,
        held_count: 1,
        dispatchable_count: 1
      )
      expect(counts.for(endpoint_b)).to eq(
        backlog_total: 1,
        held_count: 0,
        dispatchable_count: 1
      )
    end
  end
end
