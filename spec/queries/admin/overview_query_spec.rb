require 'rails_helper'

describe Admin::OverviewQuery do
  describe '.call' do
    def summary
      described_class.call
    end

    it 'counts accounts by role and confirmation state' do
      before_creation = summary[:accounts]

      create(:user).tap { |user| user.add_role(:admin) }
      create_list(:user, 2).each { |user| user.add_role(:support) }
      create(:user, :need_confirmation)
      create(:user)

      accounts = summary[:accounts]

      expect(accounts[:total] - before_creation[:total]).to eq(5)
      expect(accounts[:admins] - before_creation[:admins]).to eq(1)
      expect(accounts[:support] - before_creation[:support]).to eq(2)
      expect(accounts[:unconfirmed] - before_creation[:unconfirmed]).to eq(1)
    end

    it 'counts projects' do
      before_creation = summary[:projects][:total]

      create_list(:project, 2)

      expect(summary[:projects][:total] - before_creation).to eq(2)
    end

    it 'summarizes endpoint availability and queued deliveries' do
      before_creation = summary[:endpoints]
      project = create(:project)
      open_endpoint = create(:endpoint, project: project)
      open_endpoint.update_columns(circuit_state: 'circuit_open', queued_message_count: 3)
      disabled_endpoint = create(:endpoint, project: project)
      disabled_endpoint.update_columns(circuit_state: 'disabled', queued_message_count: 4)
      create(:endpoint, project: project, active: false)
      archived_endpoint = create(:endpoint, project: project)
      archived_endpoint.update_columns(archived_at: Time.current)

      endpoints = summary[:endpoints]

      expect(endpoints[:active] - before_creation[:active]).to eq(2)
      expect(endpoints[:circuit_open] - before_creation[:circuit_open]).to eq(1)
      expect(endpoints[:disabled] - before_creation[:disabled]).to eq(1)
      expect(endpoints[:queued_messages] - before_creation[:queued_messages]).to eq(7)
    end

    it 'summarizes rolled up deliveries, held deliveries and due retries' do
      before_creation = summary[:deliveries]
      project = create(:project)
      endpoint = create(:endpoint, project: project)

      create(:delivery_metric, project: project, day: Date.current,
                               attempts_count: 10, successes_count: 6, failures_count: 4)
      create(:delivery_metric, project: create(:project), day: Date.current,
                               attempts_count: 5, successes_count: 2, failures_count: 3)
      create(:delivery_metric, project: project, day: 31.days.ago.to_date,
                               attempts_count: 99, successes_count: 98, failures_count: 1)

      create(:message, project: project, endpoint: endpoint, status: :delivering)
      create(:message, project: project, endpoint: endpoint, status: :pending)
      held_message = create(:message, project: project, endpoint: endpoint)
      held_message.hold!(reason: 'endpoint_circuit_open')
      create(:message, project: project, endpoint: endpoint, next_retry_at: 1.minute.ago)
      create(:message, project: project, endpoint: endpoint, next_retry_at: 1.hour.from_now)

      deliveries = summary[:deliveries]

      expect(deliveries[:window_days]).to eq(30)
      expect(deliveries[:total_attempts] - before_creation[:total_attempts]).to eq(15)
      expect(deliveries[:succeeded_attempts] - before_creation[:succeeded_attempts]).to eq(8)
      expect(deliveries[:failed_attempts] - before_creation[:failed_attempts]).to eq(7)
      expect(deliveries[:success_rate]).to be > 0
      expect(deliveries[:in_flight] - before_creation[:in_flight]).to eq(4)
      expect(deliveries[:held] - before_creation[:held]).to eq(1)
      expect(deliveries[:retries_due] - before_creation[:retries_due]).to eq(1)
    end
  end
end
