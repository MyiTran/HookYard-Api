module Api
  module V1
    module Projects
      class MessagesController < Api::V1::BaseController
        before_action :set_project

        def index
          endpoint = @project.endpoints.find(params[:endpoint_id])
          authorize endpoint, :show?

          scope = EndpointMessagesQuery.call(policy_scope(endpoint.messages))
          pagy, messages = paginate(scope)

          render_resource_collection(messages, each_serializer: MessageSerializer, pagy: pagy)
        end

        def show
          message = policy_scope(Message)
                    .where(endpoint_id: @project.endpoints.select(:id), event_id: @project.events.select(:id))
                    .preload(:event, :delivery_attempts, endpoint: :project)
                    .find(params[:id])
          authorize message

          render_resource(message, serializer: MessageDetailSerializer)
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end
      end
    end
  end
end
