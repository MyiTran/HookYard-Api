module Replays
  class BulkPolicy
    MAX_ITEMS_PER_RUN = 20_000

    LIMIT_MESSAGE = 'This recovery has %<eligible>d eligible deliveries. A single recovery can contain at most ' \
                    '%<limit>d. Narrow the filters and try again.'

    class << self
      def eligible_count(project:, filters:, as_of: nil)
        ReplayCandidatesQuery.count(ReplayCandidatesQuery.for_project(project), as_of: as_of, **symbolized(filters))
      end

      def over_limit?(eligible_count)
        eligible_count > MAX_ITEMS_PER_RUN
      end

      def enforce!(project:, filters:, as_of: nil)
        eligible = eligible_count(project: project, filters: filters, as_of: as_of)
        return eligible unless over_limit?(eligible)

        raise_limit_error!(eligible: eligible)
      end

      def raise_limit_error!(eligible:)
        raise ApiError::BulkReplayLimitExceededError.new(
          message: format(LIMIT_MESSAGE, eligible: eligible, limit: MAX_ITEMS_PER_RUN),
          eligible: eligible,
          limit: MAX_ITEMS_PER_RUN
        )
      end

      private

      def symbolized(filters)
        filters.to_h.symbolize_keys
      end
    end
  end
end
