module Replays
  class Preview < ApplicationOperation
    SAMPLE_LIMIT = 5

    Result = Struct.new(:requested_count, :eligible_count, :blocked_count, :sample, :max_items_per_run, :over_limit,
                        keyword_init: true)

    def call(project:, filters:)
      filters = filters.to_h.symbolize_keys.slice(*ReplayCandidatesQuery::FILTER_KEYS)
      scope = ReplayCandidatesQuery.for_project(project)
      requested_count = ReplayCandidatesQuery.count(scope, eligible: false, **filters)
      candidates = ReplayCandidatesQuery.call(scope, **filters)
      eligible_count = ReplayCandidatesQuery.count(scope, **filters)

      sample = candidates.reorder(created_at: :desc, id: :desc).limit(SAMPLE_LIMIT).to_a

      Result.new(
        requested_count: requested_count,
        eligible_count: eligible_count,
        blocked_count: requested_count - eligible_count,
        sample: sample,
        max_items_per_run: Replays::BulkPolicy::MAX_ITEMS_PER_RUN,
        over_limit: Replays::BulkPolicy.over_limit?(eligible_count)
      )
    end
  end
end
