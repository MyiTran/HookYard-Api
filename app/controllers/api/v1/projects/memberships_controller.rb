module Api
  module V1
    module Projects
      class MembershipsController < Api::V1::BaseController
        before_action :set_project

        def index
          authorize @project, :show?

          render_resource_collection(@project.project_memberships.includes(:user), each_serializer: ProjectMembershipSerializer)
        end

        def destroy
          membership = @project.project_memberships.find(params[:id])
          authorize membership
          membership.destroy!

          head :no_content
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end
      end
    end
  end
end
