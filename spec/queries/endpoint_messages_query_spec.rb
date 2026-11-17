require 'rails_helper'

describe EndpointMessagesQuery do
  let(:project) { create(:project) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:event) { create(:event, project: project) }

  def results
    described_class.call(endpoint.messages).to_a
  end

  describe '.call' do
    it 'orders messages newest first' do
      older = create(:message, event: event, endpoint: endpoint, created_at: 2.hours.ago)
      newer = create(:message, event: create(:event, project: project), endpoint: endpoint, created_at: 1.hour.ago)

      expect(results.map(&:id)).to eq([newer.id, older.id])
    end

    it 'returns zero and nil attempt summary fields when a message has no attempts' do
      message = create(:message, event: event, endpoint: endpoint)

      row = results.first

      expect(row.id).to eq(message.id)
      expect(row.attempt_count).to eq(0)
      expect(row.last_attempt_at).to be_nil
      expect(row.last_response_status).to be_nil
      expect(row.last_duration_ms).to be_nil
      expect(row.last_error_type).to be_nil
    end

    it 'returns the count and fields of the latest attempt' do
      message = create(:message, event: event, endpoint: endpoint)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 500, duration_ms: 30)
      latest = create(:delivery_attempt, message: message, attempt_number: 2, response_status: 200, duration_ms: 12)
      message.update_columns(attempt_count: 2)

      row = results.first

      expect(row.attempt_count).to eq(2)
      expect(row.last_response_status).to eq(200)
      expect(row.last_duration_ms).to eq(12)
      expect(row.last_error_type).to be_nil
      expect(row.last_attempt_at).to be_within(1.second).of(latest.created_at)
    end

    it 'exposes the transport error of the latest attempt' do
      message = create(:message, event: event, endpoint: endpoint)
      create(:delivery_attempt, message: message, attempt_number: 1, response_status: 200, duration_ms: 12)
      create(:delivery_attempt, message: message, attempt_number: 2, error_type: 'Net::OpenTimeout', duration_ms: 10_000)

      message.update_columns(attempt_count: 2)

      row = results.first

      expect(row.attempt_count).to eq(2)
      expect(row.last_response_status).to be_nil
      expect(row.last_error_type).to eq('Net::OpenTimeout')
      expect(row.last_duration_ms).to eq(10_000)
    end

    it 'preloads the event of every message' do
      create(:message, event: event, endpoint: endpoint)

      expect(results.first.association(:event)).to be_loaded
    end
  end
end
