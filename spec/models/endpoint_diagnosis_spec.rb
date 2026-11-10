require 'rails_helper'

describe EndpointDiagnosis, type: :model do
  let(:diagnosis) { build(:endpoint_diagnosis) }

  describe 'validations' do
    context 'when the label is not an allowed diagnosis label' do
      it 'is invalid' do
        diagnosis.label = 'cosmic_rays'

        expect(diagnosis).not_to be_valid
        expect(diagnosis.errors[:label]).to be_present
      end
    end

    context 'when the suggested action is blank' do
      it 'is invalid' do
        diagnosis.suggested_action = '   '

        expect(diagnosis).not_to be_valid
        expect(diagnosis.errors[:suggested_action]).to be_present
      end
    end

    context 'when the suggested action exceeds the bound' do
      it 'is invalid' do
        diagnosis.suggested_action = 'a' * (Ai::Diagnosis::ACTION_MAX_LENGTH + 1)

        expect(diagnosis).not_to be_valid
      end
    end

    context 'when the analyzed attempt count is negative' do
      it 'is invalid' do
        diagnosis.analyzed_attempt_count = -1

        expect(diagnosis).not_to be_valid
      end
    end

    context 'when the analyzed attempt count is missing' do
      it 'is invalid' do
        diagnosis.analyzed_attempt_count = nil

        expect(diagnosis).not_to be_valid
        expect(diagnosis.errors[:analyzed_attempt_count]).to be_present
      end
    end

    context 'when the analyzed attempt count is not a whole number' do
      it 'is invalid' do
        diagnosis.analyzed_attempt_count = 1.5

        expect(diagnosis).not_to be_valid
      end
    end

    context 'when the source is not a known source' do
      it 'is invalid' do
        diagnosis.source = 'manual'

        expect(diagnosis).not_to be_valid
        expect(diagnosis.errors[:source]).to be_present
      end
    end

    context 'when the source is missing' do
      it 'is invalid' do
        diagnosis.source = nil

        expect(diagnosis).not_to be_valid
        expect(diagnosis.errors[:source]).to be_present
      end
    end

    context 'when the endpoint belongs to another project' do
      it 'is invalid' do
        diagnosis.project = create(:project)

        expect(diagnosis).not_to be_valid
      end
    end
  end

  describe '.newest_first' do
    it 'orders the diagnoses from the most recent to the oldest' do
      stale = create(:endpoint_diagnosis, created_at: 2.hours.ago)
      newest = create(:endpoint_diagnosis, created_at: 1.hour.ago)

      expect(described_class.newest_first.to_a).to eq([newest, stale])
    end
  end

  describe 'invalid labels' do
    it 'never persists a label outside the allowed labels' do
      diagnosis.label = 'cosmic_rays'

      expect { diagnosis.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(described_class.where(label: 'cosmic_rays')).to be_empty
    end
  end

  describe '#source' do
    it 'records a validated provider answer as ai with its model' do
      diagnosis = build(:endpoint_diagnosis, :ai)

      expect(diagnosis.save).to be(true)
      expect(diagnosis.reload).to have_attributes(
        source: EndpointDiagnosis::SOURCE_AI,
        model: Ai::GeminiFailureDiagnoser::DEFAULT_MODEL
      )
      expect(diagnosis).to be_ai
    end

    it 'records a deterministic answer as fallback without a model' do
      diagnosis = create(:endpoint_diagnosis)

      expect(diagnosis).to be_fallback
      expect(diagnosis.model).to be_nil
    end
  end
end
