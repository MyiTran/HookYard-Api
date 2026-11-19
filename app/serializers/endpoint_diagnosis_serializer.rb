class EndpointDiagnosisSerializer < ApplicationSerializer
  fields :label, :suggested_action, :source, :analyzed_attempt_count, :created_at
end
