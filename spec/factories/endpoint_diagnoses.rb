FactoryBot.define do
  factory :endpoint_diagnosis do
    endpoint
    project { endpoint.project }
    association :requested_by, factory: :user
    label { Ai::Diagnosis::UNKNOWN }
    suggested_action { Ai::FallbackDiagnosis::ACTIONS.fetch(Ai::Diagnosis::UNKNOWN) }
    source { EndpointDiagnosis::SOURCE_FALLBACK }
    analyzed_attempt_count { 0 }

    trait :ai do
      label { Ai::Diagnosis::HANDLER_TIMEOUT }
      suggested_action { 'Raise the receiver timeout and retry the delivery.' }
      source { EndpointDiagnosis::SOURCE_AI }
      model { Ai::GeminiFailureDiagnoser::DEFAULT_MODEL }
      analyzed_attempt_count { 1 }
    end
  end
end
