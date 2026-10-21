module Api
  module V1
    module Projects
      class ApiCredentialsController < Api::V1::BaseController
        before_action :set_project

        def index
          authorize ProjectApiCredential.new(project: @project)

          pagy, credentials = paginate(@project.project_api_credentials.order(created_at: :desc))

          render_resource_collection(
            credentials,
            each_serializer: ProjectApiCredentialSerializer,
            pagy: pagy
          )
        end

        def create
          authorize ProjectApiCredential.new(project: @project)

          credential, raw_token = ProjectApiCredentials::Create.call(
            project: @project,
            name: credential_params[:name]
          )

          render_resource(
            credential,
            serializer: ProjectApiCredentialSerializer,
            token: raw_token,
            view: :with_token,
            status: :created
          )
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def credential_params
          params.require(:api_credential).permit(:name)
        end
      end
    end
  end
end
