module Api
  module V1
    class ProjectsController < BaseController
      def index
        render_resource_collection(policy_scope(Project).order(created_at: :desc), each_serializer: ProjectSerializer, current_user: current_user)
      end

      def show
        project = policy_scope(Project).find(params[:id])
        authorize project

        render_resource(project, current_user: current_user)
      end

      def create
        authorize Project
        project = ::Projects::Create.call(user: current_user, attributes: project_params)

        render_resource(project, current_user: current_user, status: :created)
      end

      def update
        project = policy_scope(Project).find(params[:id])
        authorize project
        project.update!(project_params)

        render_resource(project, current_user: current_user)
      end

      def destroy
        project = policy_scope(Project).find(params[:id])
        authorize project
        project.destroy!

        head :no_content
      end

      private

      def project_params
        params.require(:project).permit(:name)
      end
    end
  end
end
