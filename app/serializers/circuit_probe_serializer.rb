# Receivers must treat a synthetic probe (`type: "endpoint.test"`) as a health
# check and must never process it as a business event.
class CircuitProbeSerializer < ApplicationSerializer
  identifier :id

  fields :status, :request_id, :webhook_id, :signing_secret_version, :started_at, :completed_at,
         :response_status, :duration_ms, :error_type, :error_message
end
