require 'rails_helper'

describe UserDashboardQuery do
  let(:user) { create(:user, :pro) }
  let!(:owned_project) { create(:project, :with_owner, owner: user, name: 'Owned Project') }
  let!(:shared_project) do
    create(:project, name: 'Shared Project').tap do |project|
      create(:project_membership, project: project, user: user, role: :maintainer)
    end
  end
  let!(:foreign_project) { create(:project, name: 'Foreign Project') }

  let!(:owned_endpoint) { create(:endpoint, project: owned_project) }

  def dashboard
    described_class.call(user: user)
  end

  before do
    owned_endpoint.update_columns(circuit_state: 'circuit_open', queued_message_count: 2)

    create(:delivery_metric, project: owned_project, day: Date.current,
                             attempts_count: 10, successes_count: 8, failures_count: 2)
    create(:delivery_metric, project: shared_project, day: Date.current,
                             attempts_count: 5, successes_count: 4, failures_count: 1)
    create(:delivery_metric, project: foreign_project, day: Date.current,
                             attempts_count: 99, successes_count: 98, failures_count: 1)

    held_message = create(:message, project: owned_project, endpoint: owned_endpoint)
    held_message.hold!(reason: 'endpoint_circuit_open')
    create(:message, project: owned_project, endpoint: owned_endpoint, status: :delivering)
    create(:message, project: owned_project, endpoint: owned_endpoint)
    create(:message, project: owned_project, endpoint: owned_endpoint, next_retry_at: 1.minute.ago)
  end

  it 'scopes workspace counts and health to projects the user belongs to' do
    result = dashboard

    expect(result[:workspace]).to eq(
      project_count: 2,
      owned_project_count: 1,
      shared_project_count: 1
    )
    expect(result[:delivery_health]).to include(
      total: 15,
      succeeded: 12,
      failed: 3,
      in_flight: 3,
      held: 1,
      retries_due: 1,
      success_rate: 80.0
    )
    expect(result[:needs_attention]).to eq(
      open_circuit_endpoints: 1,
      held_deliveries: 1,
      retries_due: 1,
      failed_deliveries: 3
    )
  end

  it 'classifies owned and shared projects from billing ownership and membership' do
    cards = dashboard[:projects]

    owned = cards.find { |card| card[:id] == owned_project.id }
    shared = cards.find { |card| card[:id] == shared_project.id }

    expect(owned).to include(
      relationship: 'owned',
      current_user_role: 'owner',
      effective_plan: User::PRO_PLAN
    )
    expect(shared).to include(
      relationship: 'shared',
      current_user_role: 'maintainer',
      effective_plan: User::FREE_PLAN
    )
    expect(cards.map { |card| card[:id] }).not_to include(foreign_project.id)
  end

  it 'orders projects by attention priority and limits them to five' do
    cards = dashboard[:projects]

    expect(cards.size).to be <= 5
    expect(cards.first[:id]).to eq(owned_project.id)
  end

  it 'does not count circuit probes as delivery failures' do
    create(:circuit_probe, endpoint: owned_endpoint, status: :failed)

    expect(dashboard[:delivery_health][:failed]).to eq(3)
    expect(dashboard[:needs_attention][:failed_deliveries]).to eq(3)
  end

  it 'does not add a query per project' do
    baseline = sql_queries { dashboard }.size

    extra_project = create(:project, :with_owner, owner: user, name: 'Extra Project')
    extra_endpoint = create(:endpoint, project: extra_project)
    create_list(:message, 2, project: extra_project, endpoint: extra_endpoint)

    expect(sql_queries { dashboard }.size).to eq(baseline)
  end

  it 'reports completed historical deliveries after missing metrics are backfilled' do
    DeliveryMetric.delete_all
    day = 3.days.ago.to_date
    message = create(:message, project: owned_project, endpoint: owned_endpoint)
    create(:delivery_attempt, message: message, response_status: 200,
                              created_at: day.to_time(:utc) + 1.hour)
    create(:delivery_attempt, message: message, response_status: 500,
                              created_at: day.to_time(:utc) + 2.hours)
    create(:delivery_attempt, message: message, response_status: 201,
                              created_at: day.to_time(:utc) + 3.hours)

    expect(dashboard[:delivery_health][:total]).to eq(0)

    DeliveryMetric.backfill_missing!

    expect(dashboard[:delivery_health]).to include(
      total: 3,
      succeeded: 2,
      failed: 1,
      success_rate: 66.67
    )
  end
end
