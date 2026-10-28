module Api
  module V1
    class MessagesController < BaseController
      def index
        scope = MessagesQuery.call(
          policy_scope(Message),
          q: params[:q],
          project_id: params[:project_id],
          endpoint_id: params[:endpoint_id],
          status: params[:status],
          delivery_state: params[:delivery_state],
          event_type: params[:event_type],
          from: params[:from],
          to: params[:to],
          order: params[:order]
        )
        pagy, messages = paginate(scope)

        render_resource_collection(
          messages,
          each_serializer: MessageSerializer,
          view: :with_context,
          pagy: pagy
        )
      end
    end
  end
end
