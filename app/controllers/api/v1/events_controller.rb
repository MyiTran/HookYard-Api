module Api
  module V1
    class EventsController < ApplicationController
      include ProjectApiAuthentication

      def create
        result = Events::Ingest.call(project: current_project, attributes: event_params)

        render_resource(
          result.event,
          serializer: EventSerializer,
          created: result.created,
          messages_count: result.messages_count,
          status: result.created ? :accepted : :ok
        )
      end

      private

      def event_params
        params.permit(:event_type, :idempotency_key)
              .merge(payload: request.request_parameters['payload'])
      end
    end
  end
end
