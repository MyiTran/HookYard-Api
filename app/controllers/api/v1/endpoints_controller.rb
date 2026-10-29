module Api
  module V1
    class EndpointsController < BaseController
      def index
        scope = EndpointsQuery.call(
          policy_scope(Endpoint),
          q: params[:q],
          project_id: params[:project_id],
          active: params[:active],
          archived: params[:archived],
          order: params[:order]
        )
        pagy, endpoints = paginate(scope)

        endpoints = endpoints.includes(:endpoint_signing_secrets, project: :billing_owner)

        render_resource_collection(
          endpoints,
          each_serializer: EndpointSerializer,
          plan_locks: EndpointPlanLocks.new(endpoints.map(&:project)),
          pagy: pagy
        )
      end
    end
  end
end
