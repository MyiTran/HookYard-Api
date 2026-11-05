module Api
  module V1
    class MessagesController < BaseController
      def index
        scope = MessagesQuery.call(
          policy_scope(Message),
          q: params[:q],
          message_id: params[:message_id],
          request_id: params[:request_id],
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

      def replay
        message = policy_scope(Message)
                  .preload(:event, :delivery_attempts, :active_replay_item, :latest_replay_item, endpoint: :project)
                  .find(params[:id])
        authorize message, :replay?

        run = Replays::Create.call(message: message, actor: current_user)

        render_resource(run, serializer: ReplayRunSerializer, view: :with_items, status: :accepted)
      end
    end
  end
end
