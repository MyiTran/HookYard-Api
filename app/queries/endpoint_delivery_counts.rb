class EndpointDeliveryCounts
  EMPTY_COUNTS = { backlog_total: 0, held_count: 0, dispatchable_count: 0 }.freeze

  def initialize(endpoints)
    @counts_by_endpoint_id = load_counts(endpoints)
  end

  def for(endpoint)
    counts_by_endpoint_id[endpoint.id] || EMPTY_COUNTS
  end

  private

  attr_reader :counts_by_endpoint_id

  def load_counts(endpoints)
    endpoint_ids = endpoints.map(&:id)
    return {} if endpoint_ids.empty?

    Message.where(endpoint_id: endpoint_ids)
           .group(:endpoint_id)
           .select(
             :endpoint_id,
             "COUNT(*) FILTER (WHERE status NOT IN ('succeeded', 'failed')) AS backlog_total",
             "COUNT(*) FILTER (WHERE status = 'pending' AND held_at IS NOT NULL) AS held_count"
           )
           .index_by(&:endpoint_id)
           .transform_values do |row|
             backlog_total = row.backlog_total.to_i
             held_count = row.held_count.to_i

             {
               backlog_total: backlog_total,
               held_count: held_count,
               dispatchable_count: backlog_total - held_count
             }
           end
  end
end
