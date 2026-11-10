require 'rails_helper'

describe EndpointDiagnoses::Create, type: :operation do
  let(:owner) { create(:user) }
  let(:project) { create(:project, :with_owner, owner: owner) }
  let(:endpoint) { create(:endpoint, project: project) }
  let(:message) { create(:message, project: project, endpoint: endpoint, status: :failed) }
  let(:ai_result) { nil }
  let(:analyzed_attempt_count) { 1 }
  let(:diagnoser) do
    instance_double(Ai::GeminiFailureDiagnoser, call: ai_result, analyzed_attempt_count: analyzed_attempt_count)
  end
  let(:operation) { described_class.new(diagnoser: diagnoser) }

  def attempt(**attributes)
    create(:delivery_attempt, message: message, **attributes)
  end

  def attempt_for(target_message, **attributes)
    create(:delivery_attempt, message: target_message, **attributes)
  end

  def diagnose
    operation.call(endpoint: endpoint, actor: owner)
  end

  describe '.call' do
    context 'when the provider returns a validated answer' do
      let(:ai_result) do
        Ai::Diagnosis::Result.new(
          label: Ai::Diagnosis::HANDLER_TIMEOUT,
          suggested_action: 'Raise the receiver timeout and retry the delivery.',
          source: Ai::Diagnosis::SOURCE_AI,
          model: 'gemini-test-model'
        )
      end

      it 'persists the ai diagnosis with its model and attempt count' do
        attempt(response_status: 500)

        diagnosis = diagnose

        expect(diagnosis).to be_persisted
        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::HANDLER_TIMEOUT,
          suggested_action: 'Raise the receiver timeout and retry the delivery.',
          source: EndpointDiagnosis::SOURCE_AI,
          model: 'gemini-test-model',
          analyzed_attempt_count: 1,
          endpoint_id: endpoint.id,
          project_id: project.id,
          requested_by_id: owner.id
        )
      end
    end

    context 'when only some fetched attempts fit the provider budget' do
      it 'records the contexts actually sent to the provider' do
        attempt(response_status: 500, created_at: 2.minutes.ago)
        attempt(response_status: 503, created_at: 1.minute.ago)

        diagnosis = diagnose

        expect(diagnoser).to have_received(:call).with(array_including(instance_of(DeliveryAttempt)))
        expect(diagnosis.analyzed_attempt_count).to eq(analyzed_attempt_count)
      end
    end

    context 'when the provider returns nothing' do
      it 'persists the deterministic fallback for the newest attempt' do
        attempt(response_status: 401)

        diagnosis = diagnose

        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::AUTH_EXPIRED,
          source: EndpointDiagnosis::SOURCE_FALLBACK,
          model: nil,
          analyzed_attempt_count: 1
        )
      end
    end

    [
      [Ai::Diagnosis::AUTH_EXPIRED, { response_status: 401 }],
      [Ai::Diagnosis::AUTH_EXPIRED, { response_status: 403 }],
      [Ai::Diagnosis::HANDLER_TIMEOUT, { response_status: nil, error_type: Net::ReadTimeout.name }],
      [Ai::Diagnosis::ENDPOINT_GONE, { response_status: 410 }],
      [Ai::Diagnosis::UNKNOWN, { response_status: 500 }],
      [Ai::Diagnosis::UNKNOWN, { response_status: 302 }]
    ].each do |label, attributes|
      context "when the newest attempt failed with #{attributes.inspect}" do
        it "persists the #{label} fallback" do
          attempt(**attributes)

          expect(diagnose.label).to eq(label)
        end
      end
    end

    context 'when the receiver answers with a server error' do
      it 'persists the unknown fallback with a recovery action' do
        attempt(response_status: 503)

        diagnosis = diagnose

        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::UNKNOWN,
          source: EndpointDiagnosis::SOURCE_FALLBACK,
          model: nil
        )
        expect(diagnosis.suggested_action).to eq(
          Ai::FallbackDiagnosis::ACTIONS.fetch(Ai::Diagnosis::UNKNOWN)
        )
        expect(Ai::Diagnosis::LABELS).to include(diagnosis.label)
      end
    end

    context 'when the provider classifies the server error' do
      it 'persists the provider label instead of the fallback' do
        attempt(response_status: 502)
        allow(diagnoser).to receive(:call).and_return(
          Ai::Diagnosis::Result.new(
            label: Ai::Diagnosis::UNKNOWN,
            suggested_action: 'Check the receiver 5xx logs and recover the endpoint.',
            source: Ai::Diagnosis::SOURCE_AI,
            model: 'gemini-test-model'
          )
        )

        diagnosis = diagnose

        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::UNKNOWN,
          source: EndpointDiagnosis::SOURCE_AI,
          model: 'gemini-test-model'
        )
      end
    end

    context 'when the endpoint has no delivery history' do
      let(:analyzed_attempt_count) { 0 }

      it 'still persists an unknown fallback' do
        diagnosis = diagnose

        expect(diagnosis).to be_persisted
        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::UNKNOWN,
          source: EndpointDiagnosis::SOURCE_FALLBACK,
          analyzed_attempt_count: 0
        )
        expect(diagnosis.suggested_action).to be_present
      end
    end

    context 'when the endpoint has more attempts than the configured limit' do
      it 'analyzes only the newest finished attempts, newest first' do
        attempt(response_status: 500, created_at: 3.hours.ago)
        newest = attempt(response_status: 503, created_at: 1.hour.ago)
        attempt(response_status: 502, created_at: 2.hours.ago)
        create(:delivery_attempt, message: message)

        allow(Ai::AttemptContext).to receive(:attempt_limit).and_return(2)

        diagnose

        expect(diagnoser).to have_received(:call) do |attempts|
          expect(attempts.size).to eq(2)
          expect(attempts.first).to eq(newest)
          expect(attempts.map(&:response_status)).to eq([503, 502])
        end
      end
    end

    context 'when the endpoint only has successful deliveries' do
      let(:analyzed_attempt_count) { 0 }

      it 'sends no evidence to the provider and keeps the unknown fallback' do
        [200, 201, 202, 204].each { |status| attempt(response_status: status) }

        diagnosis = diagnose

        expect(diagnoser).to have_received(:call) { |analyzed| expect(analyzed).to be_empty }
        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::UNKNOWN,
          source: EndpointDiagnosis::SOURCE_FALLBACK,
          model: nil,
          analyzed_attempt_count: 0
        )
      end
    end

    context 'when successful and failed attempts are mixed' do
      let(:analyzed_attempt_count) { 3 }

      it 'sends only the failed attempts, newest first' do
        attempt(response_status: 200, created_at: 5.minutes.ago)
        rejected = attempt(response_status: 400, created_at: 3.minutes.ago)
        timeout = attempt(response_status: nil, error_type: Net::ReadTimeout.name,
                          error_message: 'execution expired', created_at: 2.minutes.ago)
        server_error = attempt(response_status: 500, created_at: 1.minute.ago)
        create(:delivery_attempt, message: message)

        diagnosis = diagnose

        expect(diagnoser).to have_received(:call).with([server_error, timeout, rejected])
        expect(diagnosis.analyzed_attempt_count).to eq(3)
      end
    end

    context 'when the failed attempts are transport failures' do
      it 'includes timeout, DNS and TLS failures' do
        timeout = attempt(response_status: nil, error_type: Net::ReadTimeout.name,
                          error_message: 'execution expired', created_at: 3.minutes.ago)
        dns = attempt(response_status: nil, error_type: SocketError.name,
                      error_message: 'getaddrinfo: Name or service not known', created_at: 2.minutes.ago)
        tls = attempt(response_status: nil, error_type: OpenSSL::SSL::SSLError.name,
                      error_message: 'certificate verify failed', created_at: 1.minute.ago)

        diagnose

        expect(diagnoser).to have_received(:call).with([tls, dns, timeout])
      end
    end

    context 'when the endpoint has circuit probes' do
      it 'never treats a circuit probe as delivery evidence' do
        create(:circuit_probe, endpoint: endpoint)
        failure = attempt(response_status: 503)

        diagnose

        expect(diagnoser).to have_received(:call).with([failure])
        expect(CircuitProbe.count).to eq(1)
      end
    end

    context 'when successes are newer than the failed attempts' do
      it 'applies the configured limit to failed attempts only' do
        attempt(response_status: 200, created_at: 1.minute.ago)
        attempt(response_status: 201, created_at: 2.minutes.ago)
        older_failure = attempt(response_status: 500, created_at: 3.minutes.ago)
        newest_failure = attempt(response_status: 400, created_at: 4.minutes.ago)
        allow(Ai::AttemptContext).to receive(:attempt_limit).and_return(2)

        diagnose

        expect(diagnoser).to have_received(:call).with([older_failure, newest_failure])
      end
    end

    context 'when the endpoint attempts come from replayed messages' do
      let(:message_a) { create(:message, project: project, endpoint: endpoint, status: :failed) }
      let(:message_b) { create(:message, project: project, endpoint: endpoint, status: :failed) }
      let(:analyzed_attempt_count) { 4 }

      def replayed_attempts
        {
          original_b: attempt_for(message_b, attempt_number: 1, response_status: 400, created_at: 4.minutes.ago),
          original_a: attempt_for(message_a, attempt_number: 1, response_status: 400, created_at: 3.minutes.ago),
          replay_b: attempt_for(message_b, attempt_number: 2, response_status: 500, created_at: 2.minutes.ago),
          replay_a: attempt_for(message_a, attempt_number: 2, response_status: 500, created_at: 1.minute.ago)
        }
      end

      it 'analyzes the replay attempts and the original attempts newest first' do
        attempts = replayed_attempts
        expected = [attempts[:replay_a], attempts[:replay_b], attempts[:original_a], attempts[:original_b]]

        diagnosis = diagnose

        expect(diagnoser).to have_received(:call) do |analyzed|
          expect(analyzed).to eq(expected)
          expect(analyzed.size).to eq(4)
        end
        expect(Ai::AttemptContext.attempt_limit).to be >= expected.size
        expect(diagnosis.analyzed_attempt_count).to eq(4)
      end

      context 'when the configured limit is smaller than the attempt history' do
        let(:analyzed_attempt_count) { 2 }

        it 'keeps only the newest attempts and drops the older originals' do
          attempts = replayed_attempts
          allow(Ai::AttemptContext).to receive(:attempt_limit).and_return(2)

          diagnosis = diagnose

          expect(diagnoser).to have_received(:call) do |analyzed|
            expect(analyzed).to eq([attempts[:replay_a], attempts[:replay_b]])
            expect(analyzed.map(&:response_status)).to eq([500, 500])
          end
          expect(diagnosis.analyzed_attempt_count).to eq(2)
        end
      end
    end

    context 'when the newest attempt timed out without any response' do
      let(:analyzed_attempt_count) { 2 }

      it 'selects it and falls back to handler_timeout' do
        attempt(response_status: 500, created_at: 5.minutes.ago)
        timeout = attempt(response_status: nil, error_type: Net::ReadTimeout.name,
                          error_message: 'execution expired', created_at: 1.minute.ago)

        diagnosis = diagnose

        expect(diagnoser).to have_received(:call) do |attempts|
          expect(attempts.first).to eq(timeout)
          expect(attempts.first.response_status).to be_nil
        end
        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::HANDLER_TIMEOUT,
          source: EndpointDiagnosis::SOURCE_FALLBACK,
          analyzed_attempt_count: 2
        )
      end
    end

    context 'when the newest attempt failed with TLS and no response' do
      it 'includes it in the provider context' do
        tls = attempt(response_status: nil, error_type: OpenSSL::SSL::SSLError.name,
                      error_message: 'certificate verify failed')

        diagnose

        expect(diagnoser).to have_received(:call) do |attempts|
          expect(attempts.first).to eq(tls)
          expect(Ai::AttemptContext.for(attempts.first)).to include(
            response_status: nil,
            failure_category: Webhooks::FailureCategory::NETWORK
          )
        end
      end
    end

    context 'when an attempt is still in flight' do
      it 'excludes it from the analysis' do
        finished = attempt(response_status: 503, created_at: 2.minutes.ago)
        create(:delivery_attempt, message: message, created_at: 1.minute.ago)

        diagnosis = diagnose

        expect(diagnoser).to have_received(:call).with([finished])
        expect(diagnosis.analyzed_attempt_count).to eq(1)
      end
    end

    context 'when the only attempt is still in flight' do
      let(:analyzed_attempt_count) { 0 }

      it 'ignores the endpoint attempt' do
        create(:delivery_attempt, message: message)

        diagnosis = diagnose

        expect(diagnosis).to have_attributes(
          label: Ai::Diagnosis::UNKNOWN,
          source: EndpointDiagnosis::SOURCE_FALLBACK,
          analyzed_attempt_count: 0
        )
      end
    end

    context 'when HTTP and transport failures are mixed' do
      it 'sorts them newest first and caps them at the configured limit' do
        allow(Ai::AttemptContext).to receive(:attempt_limit).and_return(3)
        attempt(response_status: 500, created_at: 6.minutes.ago)
        newest = attempt(response_status: nil, error_type: Net::ReadTimeout.name, error_message: 'timeout',
                         created_at: 1.minute.ago)
        third = attempt(response_status: 502, created_at: 3.minutes.ago)
        second = attempt(response_status: nil, error_type: SocketError.name, error_message: 'dns failure',
                         created_at: 2.minutes.ago)
        attempt(response_status: 503, created_at: 5.minutes.ago)

        diagnose

        expect(diagnoser).to have_received(:call) do |attempts|
          expect(attempts).to eq([newest, second, third])
        end
      end
    end

    it 'records every diagnosis instead of overwriting an earlier one' do
      attempt(response_status: 500)
      first = diagnose
      snapshot = first.reload.attributes

      second = diagnose

      expect(EndpointDiagnosis.count).to eq(2)
      expect(second.id).not_to eq(first.id)
      expect(first.reload.attributes).to eq(snapshot)
    end

    it 'keeps the earlier diagnosis when a later replay succeeds' do
      failed = attempt(response_status: 400)
      previous = diagnose
      snapshot = previous.reload.attributes
      attempt(response_status: 200)

      analyzed = []
      allow(diagnoser).to receive(:call) do |attempts|
        analyzed << attempts
        nil
      end
      latest = diagnose

      expect(analyzed.last).to eq([failed])
      expect(previous.reload.attributes).to eq(snapshot)
      expect(EndpointDiagnosis.count).to eq(2)
      expect(latest.id).not_to eq(previous.id)
    end

    it 'does not touch delivery state, circuit state, queue jobs or usage' do
      delivery = attempt(response_status: 500)
      transport_failure = attempt(response_status: nil, error_type: Net::ReadTimeout.name,
                                  error_message: 'execution expired')
      endpoint.update!(circuit_state: :circuit_open, circuit_failure_count: 2, circuit_opened_at: Time.current)
      message.update_columns(status: 'failed', attempt_count: 3, next_retry_at: 1.minute.from_now)
      before = [message.reload.attributes, delivery.reload.attributes, transport_failure.reload.attributes,
                endpoint.reload.attributes]
      usage_before = UserUsagePeriod.order(:id).map(&:attributes)
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.size

      diagnose

      expect(message.reload.attributes).to eq(before[0])
      expect(delivery.reload.attributes).to eq(before[1])
      expect(transport_failure.reload.attributes).to eq(before[2])
      expect(endpoint.reload.attributes).to eq(before[3])
      expect(DeliveryAttempt.count).to eq(2)
      expect(ReplayRun.count).to eq(0)
      expect(ReplayItem.count).to eq(0)
      expect(CircuitProbe.count).to eq(0)
      expect(EndpointDiagnosis.count).to eq(1)
      expect(UserUsagePeriod.order(:id).map(&:attributes)).to eq(usage_before)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(enqueued)
    end
  end
end
