require 'rails_helper'

describe Event, type: :model do
  describe 'validations' do
    context 'when the event type is missing' do
      it 'is invalid' do
        expect(build(:event, event_type: nil)).not_to be_valid
      end
    end

    context 'when the idempotency key is missing' do
      it 'is invalid' do
        expect(build(:event, idempotency_key: nil)).not_to be_valid
      end
    end

    context 'when the idempotency key is too long' do
      it 'is invalid' do
        expect(build(:event, idempotency_key: 'a' * 256)).not_to be_valid
      end
    end

    context 'when the payload is not a JSON object' do
      it 'is invalid' do
        expect(build(:event, payload: [1, 2])).not_to be_valid
      end
    end

    context 'when the payload is a JSON object' do
      it 'is valid' do
        expect(build(:event, payload: { 'order_id' => 'ord_1' })).to be_valid
      end
    end
  end

  describe '.fingerprint_for' do
    it 'ignores payload key order' do
      first = described_class.fingerprint_for(event_type: 'order.created', payload: { 'a' => 1, 'b' => 2 })
      second = described_class.fingerprint_for(event_type: 'order.created', payload: { 'b' => 2, 'a' => 1 })

      expect(first).to eq(second)
    end

    it 'changes when the event type or payload changes' do
      base = described_class.fingerprint_for(event_type: 'order.created', payload: { 'a' => 1 })

      expect(described_class.fingerprint_for(event_type: 'order.paid', payload: { 'a' => 1 })).not_to eq(base)
      expect(described_class.fingerprint_for(event_type: 'order.created', payload: { 'a' => 2 })).not_to eq(base)
    end
  end

  describe 'idempotency key uniqueness' do
    let(:project) { create(:project) }

    it 'rejects a duplicate key within the same project' do
      create(:event, project: project, idempotency_key: 'order-1')

      expect { create(:event, project: project, idempotency_key: 'order-1') }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'allows the same key in different projects' do
      create(:event, project: project, idempotency_key: 'order-1')

      expect(create(:event, idempotency_key: 'order-1')).to be_persisted
    end
  end
end
