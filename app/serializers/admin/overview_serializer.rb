module Admin
  class OverviewSerializer < ApplicationSerializer
    field(:generated_at) { |overview| overview[:generated_at].iso8601 }
    field(:accounts) { |overview| overview[:accounts] }
    field(:projects) { |overview| overview[:projects] }
    field(:endpoints) { |overview| overview[:endpoints] }
    field(:deliveries) { |overview| overview[:deliveries] }
  end
end
