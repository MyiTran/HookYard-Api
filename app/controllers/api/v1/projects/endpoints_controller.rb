module Api
  module V1
    module Projects
      class EndpointsController < Api::V1::BaseController
        before_action :set_project

        def index
          authorize Endpoint.new(project: @project)

          scope = EndpointsQuery.call(
            @project.endpoints,
            q: params[:q],
            active: params[:active],
            archived: params[:archived],
            order: params[:order]
          )
          pagy, endpoints = paginate(scope)

          render_resource_collection(
            endpoints.includes(:endpoint_signing_secrets),
            each_serializer: EndpointSerializer,
            pagy: pagy
          )
        end

        def show
          endpoint = @project.endpoints.find(params[:id])
          authorize endpoint

          render_resource(endpoint)
        end

        def create
          authorize Endpoint.new(project: @project)
          endpoint = Endpoints::Create.call(project: @project, attributes: endpoint_params)

          render_resource(
            endpoint,
            signing_secret: endpoint.current_signing_secret.secret,
            view: :with_signing_secret,
            status: :created
          )
        end

        def update
          endpoint = @project.endpoints.find(params[:id])
          authorize endpoint
          endpoint.update!(endpoint_params)

          render_resource(endpoint)
        end

        def destroy
          endpoint = @project.endpoints.find(params[:id])
          authorize endpoint, :archive?
          Endpoints::Archive.call(endpoint: endpoint)

          head :no_content
        end

        def rotate_signing_secret
          endpoint = @project.endpoints.find(params[:id])
          authorize endpoint, :rotate_signing_secret?
          secret = Endpoints::RotateSigningSecret.call(endpoint: endpoint)

          render_resource(endpoint, signing_secret: secret.secret, view: :with_signing_secret)
        end

        def re_enable
          endpoint = @project.endpoints.find(params[:id])
          authorize endpoint, :re_enable?
          Endpoints::ReEnable.call(endpoint: endpoint)

          render_resource(endpoint)
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def endpoint_params
          params.require(:endpoint).permit(:name, :url, :description, :active, event_types: [])
        end
      end
    end
  end
end
