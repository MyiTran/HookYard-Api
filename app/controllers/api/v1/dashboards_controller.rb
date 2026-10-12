module Api
  module V1
    class DashboardsController < BaseController
      def show
        render_resource(current_user)
      end
    end
  end
end
