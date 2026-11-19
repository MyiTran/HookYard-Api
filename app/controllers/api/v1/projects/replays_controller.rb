module Api
  module V1
    module Projects
      class ReplaysController < Api::V1::BaseController
        before_action :set_project

        def preview
          authorize ReplayRun.new(project: @project), :preview?

          preview = Replays::Preview.call(project: @project, filters: filter_params)

          render_resource(preview, serializer: ReplayPreviewSerializer)
        end

        def create
          authorize ReplayRun.new(project: @project), :create?

          run = Replays::CreateBulk.call(project: @project, actor: current_user, filters: filter_params)

          render_resource(run, serializer: ReplayRunSerializer, status: :accepted)
        end

        def show
          run = replay_scope.find(params[:id])
          authorize run

          render_resource(run, serializer: ReplayRunSerializer)
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def replay_scope
          policy_scope(ReplayRun).where(project_id: @project.id)
        end

        def filter_params
          params.permit(*ReplayRun::FILTER_KEYS).to_h
        end
      end
    end
  end
end
