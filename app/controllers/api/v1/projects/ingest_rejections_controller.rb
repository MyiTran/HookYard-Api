module Api
  module V1
    module Projects
      class IngestRejectionsController < Api::V1::BaseController
        before_action :set_project

        def index
          authorize @project, :show?

          scope = IngestRejectionsQuery.call(
            policy_scope(@project.ingest_rejections),
            reason: params[:reason],
            event_type: params[:event_type],
            from: params[:from],
            to: params[:to],
            order: params[:order]
          )
          pagy, rejections = paginate(scope)

          render_resource_collection(
            rejections,
            each_serializer: IngestRejectionSerializer,
            pagy: pagy
          )
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end
      end
    end
  end
end
