module Api
  module V1
    module Admin
      class ProjectsController < BaseController
        def index
          scope = ProjectsQuery.call(Project.all, **query_params).preload(:billing_owner)
          pagy, projects = paginate(scope)

          render_resource_collection(projects, each_serializer: ::Admin::ProjectSerializer, pagy: pagy)
        end

        def show
          project = Project.includes(:billing_owner, :project_memberships, :endpoints).find(params[:id])

          render_resource(project, serializer: ::Admin::ProjectSerializer, view: :detail)
        end

        private

        def query_params
          params.permit(:q, :account_id, :billing_owner_id, :plan, :order).to_h.symbolize_keys
        end
      end
    end
  end
end
