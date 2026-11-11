module Api
  module V1
    module Admin
      class EndpointsController < BaseController
        def index
          scope = EndpointsQuery.call(Endpoint.all, **query_params).preload(:project)
          pagy, endpoints = paginate(scope)

          render_resource_collection(endpoints, each_serializer: ::Admin::EndpointSerializer, pagy: pagy)
        end

        def show
          endpoint = Endpoint.includes(project: :billing_owner).find(params[:id])
          delivery_summary = ::Admin::EndpointSummaryQuery.call(endpoint)

          render_resource(
            endpoint,
            serializer: ::Admin::EndpointSerializer,
            view: :detail,
            delivery_summary: delivery_summary
          )
        end

        private

        def query_params
          params.permit(:q, :project_id, :circuit_state, :active, :archived, :order).to_h.symbolize_keys
        end
      end
    end
  end
end
