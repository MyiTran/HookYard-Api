module API
  module V1
    module Admin
      class DashboardsController < BaseController
        def show
          project_count = defined?(Project) ? Project.count : 0

          render json: {
            message: 'Welcome to Admin Dashboard',
            stats: {
              total_users: User.count,
              total_projects: project_count
            }
          }
        end
      end
    end
  end
end
