module EndpointDiagnoses
  class Create < ApplicationOperation
    def initialize(diagnoser: Ai::GeminiFailureDiagnoser.new)
      @diagnoser = diagnoser
    end

    def call(endpoint:, actor:)
      attempts = recent_attempts(endpoint)
      result = diagnosis(attempts)

      endpoint.endpoint_diagnoses.create!(
        project: endpoint.project,
        requested_by: actor,
        label: result.label,
        suggested_action: result.suggested_action,
        source: result.source,
        model: result.model,
        analyzed_attempt_count: diagnoser.analyzed_attempt_count
      )
    end

    private

    attr_reader :diagnoser

    def recent_attempts(endpoint)
      endpoint.delivery_attempts
              .failed_for_diagnosis
              .newest_first
              .limit(Ai::AttemptContext.attempt_limit)
              .to_a
    end

    def diagnosis(attempts)
      diagnoser.call(attempts) || Ai::FallbackDiagnosis.for(attempts.first)
    end
  end
end
