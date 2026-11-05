module Api
  module V1
    module Projects
      class EndpointDiagnosesController < Api::V1::BaseController
        before_action :set_project
        before_action :set_endpoint

        def create
          authorize EndpointDiagnosis.new(endpoint: @endpoint, project: @project), :create?
          diagnosis = EndpointDiagnoses::Create.call(endpoint: @endpoint, actor: current_user)

          render_resource(diagnosis, serializer: EndpointDiagnosisSerializer, status: :created)
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def set_endpoint
          @endpoint = @project.endpoints.find(params[:endpoint_id])
        end
      end
    end
  end
end
