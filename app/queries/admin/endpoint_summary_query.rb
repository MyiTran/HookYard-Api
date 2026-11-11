module Admin
  class EndpointSummaryQuery < ApplicationQuery
    RECENT_DELIVERY_WINDOW = 7.days

    def call(endpoint)
      {
        total: endpoint.messages.count,
        recent: endpoint.messages.where(created_at: RECENT_DELIVERY_WINDOW.ago..).count,
        held: endpoint.held_message_count
      }
    end
  end
end
