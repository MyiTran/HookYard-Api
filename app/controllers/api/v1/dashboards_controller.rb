module Api
  module V1
      class DashboardsController < BaseController
        def show
          render_resource(::UserDashboardQuery.call(user: current_user), serializer: UserDashboardSerializer)
        end
      end
  end
end
