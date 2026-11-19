module EndpointDiagnoses
  class Create < ApplicationOperation
    NO_ATTEMPTS_MESSAGE = 'No failed delivery attempts are available for diagnosis'

    def initialize(diagnoser: Ai::GeminiFailureDiagnoser.new, guard: EndpointDiagnosisGuard.new)
      @diagnoser = diagnoser
      @guard = guard
    end

    def call(endpoint:, actor:)
      guard.with_lock(endpoint:) do
        enforce_database_cooldown!(endpoint)

        attempts = recent_attempts(endpoint)
        raise ApiError::UnprocessableEntityError.new(message: NO_ATTEMPTS_MESSAGE) if attempts.empty?

        result = diagnoser.call(attempts) || Ai::FallbackDiagnosis.for(attempts)

        diagnosis = endpoint.endpoint_diagnoses.create!(
          project: endpoint.project,
          requested_by: actor,
          label: result.label,
          suggested_action: result.suggested_action,
          source: result.source,
          model: result.model,
          analyzed_attempt_count: result.analyzed_attempt_count
        )

        guard.mark_success!(endpoint:)
        diagnosis
      end
    end

    private

    attr_reader :diagnoser, :guard

    def enforce_database_cooldown!(endpoint)
      latest = endpoint.endpoint_diagnoses.order(created_at: :desc).first
      return unless latest

      remaining = EndpointDiagnosisGuard::COOLDOWN_SECONDS - (Time.current - latest.created_at)
      raise ApiError::DiagnosisCooldownError.new(retry_after: remaining.ceil) if remaining.positive?
    end

    def recent_attempts(endpoint)
      endpoint.delivery_attempts
              .failed_for_diagnosis
              .newest_first
              .limit(Ai::AttemptContext.attempt_limit)
              .to_a
    end
  end
end
