module Ai
  # Shared diagnosis contract: the labels a diagnosis may ever carry and the
  # value object returned by both the provider adapter and the fallback.
  module Diagnosis
    SIGNATURE_MISMATCH = 'signature_mismatch'
    AUTH_EXPIRED = 'auth_expired'
    ENDPOINT_MOVED = 'endpoint_moved'
    HANDLER_TIMEOUT = 'handler_timeout'
    PAYLOAD_REJECTED = 'payload_rejected'
    RATE_LIMITED = 'rate_limited'
    TLS_FAILURE = 'tls_failure'
    ENDPOINT_GONE = 'endpoint_gone'
    UNKNOWN = 'unknown'

    LABELS = [
      SIGNATURE_MISMATCH,
      AUTH_EXPIRED,
      ENDPOINT_MOVED,
      HANDLER_TIMEOUT,
      PAYLOAD_REJECTED,
      RATE_LIMITED,
      TLS_FAILURE,
      ENDPOINT_GONE,
      UNKNOWN
    ].freeze

    SOURCE_AI = 'ai'
    SOURCE_FALLBACK = 'fallback'

    ACTION_MAX_LENGTH = 240

    Result = Struct.new(:label, :suggested_action, :source, :model, keyword_init: true) do
      def ai?
        source == SOURCE_AI
      end
    end
  end
end
