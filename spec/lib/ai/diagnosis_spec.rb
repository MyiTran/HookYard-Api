require 'rails_helper'

describe Ai::Diagnosis do
  describe 'LABELS' do
    it 'exposes exactly the labels allowed by the product specification' do
      expect(described_class::LABELS).to eq(
        %w[
          signature_mismatch
          auth_expired
          endpoint_moved
          handler_timeout
          payload_rejected
          rate_limited
          tls_failure
          endpoint_gone
          unknown
        ]
      )
    end

    it 'declares every label once and keeps the list frozen' do
      expect(described_class::LABELS).to eq(described_class::LABELS.uniq)
      expect(described_class::LABELS).to be_frozen
    end

    it 'keeps the unknown label last so more specific labels come first' do
      expect(described_class::LABELS.last).to eq(described_class::UNKNOWN)
    end

    it 'does not allow labels outside the product specification' do
      expect(described_class::LABELS).not_to include('cosmic_rays')
    end
  end
end
