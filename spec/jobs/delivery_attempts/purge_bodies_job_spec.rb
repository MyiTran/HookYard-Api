require 'rails_helper'

describe DeliveryAttempts::PurgeBodiesJob, type: :job do
  describe '#perform' do
    it 'delegates the retention run to the purge operation' do
      allow(DeliveryAttempts::PurgeBodies).to receive(:call)

      described_class.new.perform

      expect(DeliveryAttempts::PurgeBodies).to have_received(:call)
    end
  end

  describe 'scheduling' do
    it 'runs on the low priority queue' do
      expect(described_class.new.queue_name).to eq('low')
    end

    it 'is registered on the daily cron schedule' do
      schedule = YAML.load_file(Rails.root.join('config/schedule.yml'))

      expect(schedule['purge_delivery_attempt_bodies']).to eq(
        'cron' => '30 2 * * *',
        'class' => 'DeliveryAttempts::PurgeBodiesJob',
        'queue' => 'low'
      )
    end
  end
end
