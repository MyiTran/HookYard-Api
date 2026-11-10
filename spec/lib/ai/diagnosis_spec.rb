require 'rails_helper'

describe Ai::Diagnosis do
  describe 'LABELS' do
    it 'includes the receiver server error label' do
      expect(described_class::RECEIVER_SERVER_ERROR).to eq('receiver_server_error')
      expect(described_class::LABELS).to include('receiver_server_error')
    end

    it 'declares every label once and keeps the list frozen' do
      expect(described_class::LABELS).to eq(described_class::LABELS.uniq)
      expect(described_class::LABELS).to be_frozen
    end

    it 'keeps the unknown label last so more specific labels come first' do
      expect(described_class::LABELS.last).to eq(described_class::UNKNOWN)
    end
  end
end
