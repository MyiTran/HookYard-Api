module Api
  module V1
    module Admin
      class DashboardsController < BaseController
        def show
          render_resource(::Admin::OverviewQuery.call, serializer: ::Admin::OverviewSerializer)
        end
      end
    end
  end
end
