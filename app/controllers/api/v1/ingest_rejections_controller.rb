module Api
  module V1
    class IngestRejectionsController < BaseController
      def index
        scope = IngestRejectionsQuery.call(policy_scope(IngestRejection), **query_params)
        pagy, rejections = paginate(scope)

        render_resource_collection(
          rejections,
          each_serializer: IngestRejectionSerializer,
          pagy: pagy
        )
      end

      private

      def query_params
        params.permit(:project_id, :reason, :event_type, :from, :to, :order).to_h.symbolize_keys
      end
    end
  end
end
