module Replays
  class Eligibility
    REASON_NOT_TERMINAL = 'message_not_terminal'
    REASON_NOT_FAILED = 'message_not_failed'
    REASON_HELD = 'message_held'
    REASON_ENDPOINT_ARCHIVED = 'endpoint_archived'
    REASON_ENDPOINT_PAUSED = 'endpoint_paused'
    REASON_ENDPOINT_DISABLED = 'endpoint_disabled'
    REASON_REPLAY_IN_PROGRESS = 'replay_in_progress'

    REASONS = [
      REASON_NOT_TERMINAL,
      REASON_NOT_FAILED,
      REASON_HELD,
      REASON_ENDPOINT_ARCHIVED,
      REASON_ENDPOINT_PAUSED,
      REASON_ENDPOINT_DISABLED,
      REASON_REPLAY_IN_PROGRESS
    ].freeze

    Result = Struct.new(:allowed, :reason, keyword_init: true) do
      alias_method :allowed?, :allowed
    end

    class << self
      def for_message(message)
        new(message).result
      end

      def summary_for(message)
        eligibility = new(message)

        {
          allowed: eligibility.result.allowed?,
          blocked_reason: eligibility.result.reason,
          active: eligibility.active_item.present?,
          last_outcome: eligibility.last_outcome
        }
      end
    end

    def initialize(message)
      @message = message
    end

    def result
      return blocked(REASON_HELD) if message.held?
      return blocked(REASON_NOT_FAILED) if message.succeeded?
      return blocked(REASON_NOT_TERMINAL) unless message.failed?

      return blocked(REASON_ENDPOINT_ARCHIVED) if endpoint.archived?
      return blocked(REASON_ENDPOINT_PAUSED) if endpoint.paused?
      return blocked(REASON_ENDPOINT_DISABLED) if endpoint.disabled?
      return blocked(REASON_REPLAY_IN_PROGRESS) if active_item.present?

      Result.new(allowed: true, reason: nil)
    end

    def active_item
      message.active_replay_item
    end

    def last_outcome
      item = message.latest_replay_item
      return nil if item.nil?

      {
        id: item.id,
        replay_run_id: item.replay_run_id,
        status: item.status,
        hold_reason: item.hold_reason,
        skip_reason: item.skip_reason,
        error_type: item.error_type,
        created_at: item.created_at,
        completed_at: item.completed_at
      }
    end

    private

    attr_reader :message

    def endpoint
      message.endpoint
    end

    def blocked(reason)
      Result.new(allowed: false, reason: reason)
    end
  end
end
