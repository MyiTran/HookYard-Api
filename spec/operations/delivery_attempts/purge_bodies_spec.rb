require 'rails_helper'

describe DeliveryAttempts::PurgeBodies, type: :operation do
  let(:now) { Time.zone.local(2026, 11, 3, 10, 0, 0) }

  def create_attempt(project:, created_at:, response_status: 200, error_type: nil, error_message: nil)
    message = create(:message, project: project)

    create(
      :delivery_attempt,
      message: message,
      created_at: created_at,
      updated_at: created_at,
      request_body: '{"id":"evt"}',
      response_status: response_status,
      response_body: 'ok',
      response_headers: { 'content-type' => 'text/plain' },
      duration_ms: 42,
      error_type: error_type,
      error_message: error_message
    )
  end

  describe '.call' do
    context 'when the billing owner is on the free plan' do
      let(:project) { create(:project, :with_owner, owner: create(:user, plan: User::FREE_PLAN)) }

      it 'purges the bodies of an attempt older than three days' do
        attempt = create_attempt(project: project, created_at: now - 4.days)

        described_class.call(now: now)

        attempt.reload
        expect(attempt.request_body).to be_nil
        expect(attempt.response_body).to be_nil
        expect(attempt.bodies_purged_at).to eq(now)
      end

      it 'applies the same retention window to replay attempts' do
        message = create(:message, project: project)
        item = create(:replay_item, message: message)
        attempt = create(
          :delivery_attempt,
          message: message,
          replay_item: item,
          created_at: now - 4.days,
          updated_at: now - 4.days,
          response_status: 204
        )

        described_class.call(now: now)

        expect(attempt.reload.bodies_purged_at).to eq(now)
        expect(item.reload).to be_persisted
      end

      it 'keeps the bodies of an attempt younger than three days' do
        attempt = create_attempt(project: project, created_at: now - 2.days)

        described_class.call(now: now)

        expect(attempt.reload.request_body).to eq('{"id":"evt"}')
        expect(attempt.response_body).to eq('ok')
        expect(attempt.bodies_purged_at).to be_nil
      end

      it 'keeps the body of an attempt created exactly at the retention boundary' do
        attempt = create_attempt(project: project, created_at: now - 3.days)

        described_class.call(now: now)

        expect(attempt.reload.bodies_purged_at).to be_nil
      end

      it 'keeps safe delivery metadata after the bodies are purged' do
        attempt = create_attempt(project: project, created_at: now - 4.days, response_status: 500)
        original = attempt.attributes.slice('request_url', 'request_id', 'http_method', 'signed_at')

        described_class.call(now: now)

        attempt.reload
        expect(attempt).to have_attributes(response_status: 500, duration_ms: 42)
        expect(attempt.attributes.slice('request_url', 'request_id', 'http_method', 'signed_at')).to eq(original)
        expect(attempt.response_headers).to eq('content-type' => 'text/plain')
        expect(attempt.failure_category).to eq('http_error')
      end

      it 'purges the body of a completed transport failure' do
        attempt = create_attempt(
          project: project, created_at: now - 4.days, response_status: nil,
          error_type: 'Net::ReadTimeout', error_message: 'execution expired'
        )

        described_class.call(now: now)

        expect(attempt.reload.response_body).to be_nil
        expect(attempt.error_type).to eq('Net::ReadTimeout')
        expect(attempt.bodies_purged_at).to eq(now)
      end

      it 'never touches an attempt that is still in flight' do
        attempt = create_attempt(project: project, created_at: now - 10.days, response_status: nil)

        described_class.call(now: now)

        attempt.reload
        expect(attempt.request_body).to eq('{"id":"evt"}')
        expect(attempt.response_body).to eq('ok')
        expect(attempt.bodies_purged_at).to be_nil
      end
    end

    context 'when the billing owner is on the pro plan' do
      let(:project) { create(:project, :with_owner, owner: create(:user, plan: User::PRO_PLAN)) }

      it 'keeps the bodies of an attempt that is only four days old' do
        attempt = create_attempt(project: project, created_at: now - 4.days)

        described_class.call(now: now)

        expect(attempt.reload.request_body).to eq('{"id":"evt"}')
        expect(attempt.bodies_purged_at).to be_nil
      end

      it 'purges the bodies of an attempt older than thirty days' do
        attempt = create_attempt(project: project, created_at: now - 31.days)

        described_class.call(now: now)

        expect(attempt.reload.request_body).to be_nil
        expect(attempt.bodies_purged_at).to eq(now)
      end
    end

    context 'when the plan changes between runs' do
      let(:owner) { create(:user, plan: User::FREE_PLAN) }
      let(:project) { create(:project, :with_owner, owner: owner) }
      let!(:attempt) { create_attempt(project: project, created_at: now - 5.days) }

      it 'applies the plan the billing owner has when the run happens' do
        owner.update!(plan: User::PRO_PLAN)
        described_class.call(now: now)

        expect(attempt.reload.bodies_purged_at).to be_nil

        owner.update!(plan: User::FREE_PLAN)
        described_class.call(now: now)

        expect(attempt.reload.bodies_purged_at).to eq(now)
      end
    end

    context 'when the same window is purged again' do
      let(:project) { create(:project, :with_owner, owner: create(:user, plan: User::FREE_PLAN)) }
      let!(:attempt) { create_attempt(project: project, created_at: now - 4.days) }

      it 'is idempotent and does not rewrite the purge marker' do
        expect(described_class.call(now: now)).to eq(1)
        expect(described_class.call(now: now + 1.day)).to eq(0)
        expect(attempt.reload.bodies_purged_at).to eq(now)
      end
    end

    context 'when there are more attempts than the batch size' do
      let(:project) { create(:project, :with_owner, owner: create(:user, plan: User::FREE_PLAN)) }
      let!(:attempts) { Array.new(5) { create_attempt(project: project, created_at: now - 4.days) } }

      it 'purges every batch with a bounded number of statements' do
        statements = sql_queries { described_class.call(now: now, batch_size: 2) }

        expect(attempts.map { |attempt| attempt.reload.bodies_purged_at }).to all(eq(now))
        expect(statements.grep(/\AUPDATE/).size).to eq(3)
      end

      it 'issues a constant number of statements for a single batch' do
        statements = sql_queries { described_class.call(now: now, batch_size: 100) }

        expect(attempts.map { |attempt| attempt.reload.bodies_purged_at }).to all(eq(now))
        expect(statements.grep(/\AUPDATE/).size).to eq(1)
        expect(statements.grep(/\ASELECT/).size).to eq(2)
      end
    end

    context 'when another worker purges a selected record first' do
      let(:project) { create(:project, :with_owner, owner: create(:user, plan: User::FREE_PLAN)) }
      let!(:already_purged) { create_attempt(project: project, created_at: now - 4.days) }
      let!(:still_pending) { create_attempt(project: project, created_at: now - 4.days) }
      let(:other_run_at) { now - 1.hour }
      let(:stale_batch_ids) { [already_purged.id, still_pending.id] }

      before { described_class.new.send(:purge, [already_purged.id], other_run_at) }

      it 'counts only the records it actually purged' do
        expect(described_class.new.send(:purge, stale_batch_ids, now)).to eq(1)
      end

      it 'does not overwrite the marker or the metadata of the record purged by the other worker' do
        snapshot = already_purged.reload.attributes

        described_class.new.send(:purge, stale_batch_ids, now)

        expect(already_purged.reload.attributes).to eq(snapshot)
        expect(already_purged.bodies_purged_at).to eq(other_run_at)
      end

      it 'purges the record that is still eligible when the batch was collected' do
        described_class.new.send(:purge, stale_batch_ids, now)

        expect(still_pending.reload.bodies_purged_at).to eq(now)
        expect(still_pending.request_body).to be_nil
        expect(still_pending.response_body).to be_nil
      end
    end

    context 'when a stale batch still contains an attempt that never completed' do
      let(:project) { create(:project, :with_owner, owner: create(:user, plan: User::FREE_PLAN)) }
      let!(:in_flight) { create_attempt(project: project, created_at: now - 10.days, response_status: nil) }

      it 'never purges it and reports zero purged rows' do
        expect(described_class.new.send(:purge, [in_flight.id], now)).to eq(0)

        in_flight.reload
        expect(in_flight.request_body).to eq('{"id":"evt"}')
        expect(in_flight.response_body).to eq('ok')
        expect(in_flight.bodies_purged_at).to be_nil
      end
    end

    context 'with an invalid batch size' do
      it 'raises instead of scanning without a bound' do
        expect { described_class.call(now: now, batch_size: 0) }.to raise_error(ArgumentError)
      end
    end
  end
end
